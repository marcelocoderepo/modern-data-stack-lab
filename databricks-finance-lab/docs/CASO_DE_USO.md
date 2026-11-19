# Caso de uso — Radar de Saúde Financeira das Companhias Abertas

## 1. O problema de negócio

A **área de Crédito Corporativo** de um banco médio (ou a área de *research* de uma gestora)
acompanha cerca de 400 companhias abertas brasileiras não financeiras. Todo ano, depois que as
empresas publicam as Demonstrações Financeiras Padronizadas (DFP) na CVM, os analistas:

1. abrem o site da CVM empresa por empresa, copiam balanço e DRE para planilhas;
2. calculam na mão margem, ROE, liquidez e alavancagem;
3. comparam com a Selic/CDI e a inflação do ano, que buscam em outro site (Banco Central);
4. montam uma apresentação para o comitê de crédito.

**Dores reais desse processo:**

| Dor | Consequência |
|---|---|
| Copiar e colar de ~400 empresas leva semanas | O comitê decide com números atrasados |
| Empresas **reapresentam** demonstrações (nova versão da DFP) | A planilha fica com o número antigo, sem ninguém perceber |
| Cada analista calcula o indicador de um jeito (PL final vs. PL médio, com ou sem aplicações no caixa) | Indicadores não comparáveis entre empresas |
| Bancos e seguradoras têm plano de contas diferente | Margens e liquidez calculadas para eles não fazem sentido e distorcem as médias do setor |
| Selic saiu de 2% (2020) para 15% (2025) | Uma empresa com ROE de 12% **criava** valor em 2021 e **destrói** valor em 2025 — e ninguém revisa a régua |
| Diretoria faz perguntas ad-hoc ("quais empresas de energia estão alavancadas acima de 3x?") | Cada pergunta vira um pedido para o time de dados |

## 2. Perguntas que a solução precisa responder

**Comitê de crédito (dashboard):**

- Quantas empresas da carteira estão em situação **crítica** este ano? Esse número está piorando?
- O ROE mediano das companhias está acima ou abaixo do CDI? Desde quando?
- Quais setores concentram empresas em risco?
- Quais empresas combinam **alta alavancagem** (dívida líquida/EBIT) e **baixa rentabilidade**?

**Analistas e diretoria (Genie, em linguagem natural):**

- "Quais as 10 empresas de Energia Elétrica com maior dívida líquida/EBIT em 2025?"
- "Mostre a evolução do ROE real da WEG desde 2020."
- "Quais empresas tiveram ROE acima do CDI em todos os anos?"
- "Quantas empresas reapresentaram a DFP de 2024?"
- "Compare a margem EBIT do setor de Alimentos com a mediana de todas as empresas."

## 3. Fontes de dados (públicas e gratuitas)

| Fonte | Conteúdo | Formato | Frequência | URL |
|---|---|---|---|---|
| CVM — DFP | Balanço Patrimonial (ativo e passivo) e DRE consolidados de todas as companhias abertas | ZIP com CSV `;`, ISO-8859-1 | Anual, com reapresentações a qualquer momento | `dados.cvm.gov.br/dados/CIA_ABERTA/DOC/DFP/DADOS/` |
| CVM — Cadastro | Setor, situação do registro, mercado, controle acionário | CSV `;`, ISO-8859-1 | Diária | `dados.cvm.gov.br/dados/CIA_ABERTA/CAD/DADOS/` |
| Banco Central — SGS | Selic meta (432), CDI anualizado (4389), IPCA mensal (433), IPCA 12m (13522), dólar PTAX (1) | API JSON | Diária / mensal | `api.bcb.gov.br/dados/serie/bcdata.sgs.{codigo}/dados` |

Particularidades reais que o pipeline trata:

- **Encoding Latin-1** nos arquivos da CVM → convertido para UTF-8 na landing.
- **Escala**: valores vêm em `MIL` ou `UNIDADE` (`ESCALA_MOEDA`) → normalizado para reais.
- **ÚLTIMO x PENÚLTIMO**: cada DFP traz o ano atual e o anterior (comparativo) → usamos só o `ÚLTIMO`.
- **Versões**: a mesma DFP pode ter versão 1, 2, 3... → AUTO CDC fica com a mais recente (SCD 1) e guarda o histórico (SCD 2).
- **Modelo contábil de instituições financeiras** → detectado pelo setor e pela descrição da conta 3.01, e excluído dos indicadores operacionais.
- **O número da conta muda entre planos de contas** (lucro: 3.11 no geral, 3.09 em bancos; PL: 2.03 no geral, 2.07/2.08 em bancos) → lucro, lucro antes do IR e PL são mapeados pela **descrição** da conta, com o código como fallback; contas sem equivalente ficam nulas para bancos.
- **Acentos nos nomes** ("ITAÚ") → coluna `nome_busca` em minúsculas e sem acento, usada pelo Genie para filtrar.
- **Dados pessoais** no cadastro (nome, e-mail e telefone de diretores) → não passam da bronze (LGPD).
- **API do BCB instável** e com limite de janela para séries diárias → extração ano a ano com retry.

## 4. Arquitetura medalhão

| Camada | Tabela | Tipo SDP | O que faz |
|---|---|---|---|
| Landing | Volume `bronze.landing` | — | Arquivos brutos (CSV/JSON) |
| Bronze | `bronze.cvm_dfp_contas` | Streaming table (3 append flows, Auto Loader) | Linhas cruas das DFPs |
| Bronze | `bronze.cvm_cadastro` | Materialized view | Snapshot cru do cadastro |
| Bronze | `bronze.bcb_sgs` | Streaming table (Auto Loader) | Observações cruas das séries |
| Silver | `silver.dfp_contas` | Streaming table + **AUTO CDC SCD 1** | Conta contábil vigente por empresa/data |
| Silver | `silver.dfp_contas_historico` | Streaming table + **AUTO CDC SCD 2** | Histórico de reapresentações |
| Silver | `silver.empresas` | Materialized view | Cadastro limpo, sem PII, setor normalizado |
| Silver | `silver.bcb_series` | Streaming table + AUTO CDC SCD 1 | Séries macro tipadas |
| Gold | `gold.dim_empresa` | Materialized view | Dimensão empresa |
| Gold | `gold.fato_demonstracoes` | Materialized view | Contas-chave pivotadas (empresa x ano) |
| Gold | `gold.macro_anual` / `gold.macro_mensal` | Materialized view | Selic, CDI, IPCA, dólar |
| Gold | `gold.indicadores_financeiros` | Materialized view | **Tabela principal**: 25+ indicadores + semáforo de risco |
| Gold | `gold.benchmark_setorial` | Materialized view | Medianas por setor e ano |

## 5. Dicionário de indicadores

Todos os percentuais são guardados como **fração** (0,15 = 15%).

| Indicador | Fórmula | Leitura |
|---|---|---|
| Margem bruta | Resultado bruto (3.03) / Receita (3.01) | Poder de preço / eficiência produtiva |
| Margem EBIT | EBIT (3.05) / Receita | Eficiência operacional |
| Margem líquida | Lucro líquido (3.11) / Receita | Quanto da receita vira lucro |
| ROE | Lucro líquido / PL médio (início + fim ÷ 2) | Retorno ao acionista |
| ROA | Lucro líquido / Ativo total médio | Retorno sobre os ativos |
| ROE real | (1 + ROE) / (1 + IPCA) − 1 | Retorno acima da inflação |
| Spread ROE − CDI | ROE − CDI acumulado no ano | **< 0 = rendeu menos que a renda fixa (destrói valor)** |
| Liquidez corrente | Ativo circulante (1.01) / Passivo circulante (2.01) | < 1 = aperto de caixa no curto prazo |
| Liquidez seca | (AC − Estoques) / PC | Liquidez sem depender de vender estoque |
| Liquidez imediata | (Caixa + Aplicações) / PC | Capacidade de pagar já |
| Dívida bruta | Empréstimos CP (2.01.04) + LP (2.02.01) | — |
| Dívida líquida | Dívida bruta − Caixa − Aplicações | < 0 = caixa líquido |
| DL / EBIT | Dívida líquida / EBIT | Anos de EBIT para pagar a dívida; > 3x acende alerta |
| DL / PL | Dívida líquida / PL | Estrutura de capital |
| Cobertura financeira | EBIT / despesa financeira líquida (−3.06) | < 1,5x = juros consomem a operação |
| Crescimento real da receita | (1 + crescimento nominal) / (1 + IPCA) − 1 | Crescimento acima da inflação |

### Semáforo de risco (`classificacao_risco`)

A primeira regra verdadeira vence (o motivo vai para `motivo_risco`):

| Ordem | Regra | Classificação |
|---|---|---|
| 1 | PL ≤ 0 | Crítico |
| 2 | EBIT ≤ 0 e dívida líquida > 0 | Crítico |
| 3 | Liquidez corrente < 1 e DL/EBIT > 4 | Crítico |
| 4 | DL/EBIT > 3 | Atenção |
| 5 | Liquidez corrente < 1 | Atenção |
| 6 | Cobertura financeira < 1,5 | Atenção |
| 7 | ROE < CDI do ano | Atenção |
| — | Nenhuma das anteriores | Saudável |

> São regras de **triagem** simples e auditáveis, para priorizar onde o analista olha primeiro —
> não substituem uma análise de crédito completa. Ajuste os limites em `src/pipeline/gold.sql`.

## 6. Resultados de referência (rodada local de validação, DFP 2020–2025)

Rodando a mesma lógica de silver e gold localmente sobre os dados reais extraídos em nov/2026:

| Métrica | Valor |
|---|---|
| Contas contábeis na silver (versão vigente) | 593.829 |
| Linhas em `gold.indicadores_financeiros` (empresa x ano) | 2.550 |
| CDI acumulado 2025 | 14,32% |
| IPCA 2025 | 4,26% |
| WEG — ROE 2025 | 32,5% (spread de +18,2 p.p. sobre o CDI, caixa líquido) |
| Petrobras — ROE 2022 → 2024 | 50,1% → 9,9% (abaixo do CDI em 2024) |
| Empresas ATIVAS "Saudável": 2021 → 2025 | 149 → 86 (efeito do ciclo de alta da Selic) |

Esses números servem para você conferir se o seu pipeline no Databricks chegou ao mesmo lugar.
Pequenas diferenças são esperadas se a CVM tiver publicado novas versões depois.
