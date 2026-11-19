# Genie — "Analista de Crédito Virtual"

O Genie responde perguntas em português gerando SQL sobre as tabelas gold. A qualidade das
respostas depende de três coisas, nesta ordem: **comentários das tabelas/colunas** (já criados
pelo pipeline em `gold.sql`), **instruções gerais** e **exemplos de SQL**.

## 1. Criar o espaço

1. No menu lateral: **Genie → New**.
2. **Data**: adicione as tabelas (troque `workspace` se usou outro catálogo):
   - `workspace.gold.indicadores_financeiros`  ← principal
   - `workspace.gold.benchmark_setorial`
   - `workspace.gold.dim_empresa`
   - `workspace.gold.macro_anual`
   - `workspace.gold.fato_demonstracoes`
   - `workspace.silver.dfp_contas_historico` (para perguntas sobre reapresentações)
3. **Warehouse**: o mesmo SQL Warehouse do dashboard (na Free Edition, o *Serverless Starter Warehouse*).
4. **Title**: `Analista de Crédito Virtual — Companhias Abertas`
5. **Description**: `Pergunte sobre rentabilidade, endividamento e risco das companhias abertas brasileiras (CVM) comparados com Selic, CDI e IPCA (Banco Central).`

## 2. Instruções gerais (cole em *Instructions → General instructions*)

```text
Você apoia analistas de crédito e research que avaliam companhias abertas brasileiras.

Dados e unidades:
- Todos os indicadores percentuais (roe, roa, margens, spread_roe_cdi, cdi_acumulado, ipca_acumulado,
  selic_media, crescimento_receita) estão em FRAÇÃO: 0.15 significa 15%. Ao exibir, multiplique por 100
  e mostre com o símbolo %, com 1 casa decimal.
- Valores monetários (receita_liquida, lucro_liquido, ebit, divida_liquida etc.) estão em REAIS.
  Ao exibir, mostre em R$ milhões (divida por 1e6) ou R$ bilhões (1e9), dizendo a unidade.
- Liquidez, divida_liquida_ebit, divida_liquida_pl e cobertura_financeira estão em "vezes" (x).

Regras de negócio:
- SEMPRE inclua situacao = 'ATIVO' em contagens, totais, rankings e listas de empresas, mesmo que o usuário
  não diga "ativas". Só remova o filtro se o usuário pedir explicitamente empresas canceladas ou suspensas.
- "Último ano" ou "ano mais recente" = MAX(ano) em gold.macro_anual com meses_ipca = 12.
- "Cria valor" = cria_valor = true (ROE acima do CDI do ano). "Destrói valor" = cria_valor = false.
- "Alavancada" = divida_liquida_ebit > 3. "Muito alavancada" = divida_liquida_ebit > 4.
- "Em risco" = classificacao_risco IN ('Crítico', 'Atenção'). "Crítica" = classificacao_risco = 'Crítico'.
- Para buscar empresa por nome, use a coluna nome_busca (minúsculas, sem acento) com LIKE e o termo também
  em minúsculas e sem acento: nome_busca LIKE '%itau%' (nunca ILIKE em nome_empresa com acento).
  Exiba sempre nome_empresa.
- "Últimos N anos" = ano > (último ano) - N, onde último ano = MAX(ano) em gold.macro_anual com meses_ipca = 12.
  Nunca use LIMIT N sobre a coluna ano sem DISTINCT.
- Nomes populares: "Itaú" = nome_busca LIKE '%itau unibanco%' (Itaúsa é a holding, outra empresa);
  "Bradesco" = nome_busca LIKE 'banco bradesco%'; "Petrobras" = nome_busca LIKE 'petrobras%'.
- Para comparar uma empresa com o setor, use gold.benchmark_setorial (medianas), não médias simples.
- Em rankings de setores, considere apenas setores com qtd_empresas >= 5 e mostre qtd_empresas,
  porque proporções em setores com 2 ou 3 empresas enganam.
- Bancos e seguradoras NÃO estão em gold.indicadores_financeiros (plano de contas diferente).
  Para eles use gold.fato_demonstracoes + gold.dim_empresa: ROE = lucro_liquido / patrimonio_liquido.
  Nessas empresas ebit e resultado_financeiro são nulos; avise o usuário que liquidez, margens e
  alavancagem não se aplicam a instituições financeiras.
- Reapresentação = versao_dfp > 1 em gold.indicadores_financeiros, ou várias linhas para a mesma conta
  em silver.dfp_contas_historico.

Ao responder rankings, mostre também nome_empresa, setor e ano.
```

## 3. Exemplos de SQL (*Instructions → SQL queries*)

Adicione cada um como exemplo com a pergunta correspondente — o Genie usa como referência.

**"Quais empresas mais alavancadas de Energia Elétrica no último ano?"**
```sql
SELECT nome_empresa, ano,
       ROUND(divida_liquida_ebit, 2)        AS dl_ebit_x,
       ROUND(divida_liquida / 1e9, 1)       AS divida_liquida_bi,
       classificacao_risco
FROM workspace.gold.indicadores_financeiros
WHERE setor = 'Energia Elétrica'
  AND situacao = 'ATIVO'
  AND ano = (SELECT MAX(ano) FROM workspace.gold.macro_anual WHERE meses_ipca = 12)
  AND divida_liquida_ebit IS NOT NULL
ORDER BY divida_liquida_ebit DESC
LIMIT 10;
```

**"Quais empresas tiveram ROE acima do CDI em todos os anos?"**
```sql
SELECT nome_empresa, setor,
       COUNT(*)                         AS anos_analisados,
       ROUND(AVG(spread_roe_cdi) * 100, 1) AS spread_medio_pp
FROM workspace.gold.indicadores_financeiros
WHERE situacao = 'ATIVO'
GROUP BY nome_empresa, setor
HAVING COUNT(*) = (SELECT COUNT(DISTINCT ano) FROM workspace.gold.indicadores_financeiros)
   AND MIN(CASE WHEN cria_valor THEN 1 ELSE 0 END) = 1
ORDER BY spread_medio_pp DESC;
```

**"Evolução do ROE real da WEG"**
```sql
SELECT ano,
       ROUND(roe * 100, 1)            AS roe_pct,
       ROUND(ipca_acumulado * 100, 1) AS ipca_pct,
       ROUND(roe_real * 100, 1)       AS roe_real_pct,
       ROUND(cdi_acumulado * 100, 1)  AS cdi_pct
FROM workspace.gold.indicadores_financeiros
WHERE nome_busca LIKE '%weg%'
  AND situacao = 'ATIVO'
ORDER BY ano;
```

**"Como a margem EBIT de uma empresa se compara à mediana do setor?"**
```sql
SELECT i.nome_empresa, i.ano,
       ROUND(i.margem_ebit * 100, 1)          AS margem_ebit_pct,
       ROUND(b.margem_ebit_mediana * 100, 1)  AS mediana_setor_pct,
       ROUND((i.margem_ebit - b.margem_ebit_mediana) * 100, 1) AS diferenca_pp
FROM workspace.gold.indicadores_financeiros i
JOIN workspace.gold.benchmark_setorial b ON b.setor = i.setor AND b.ano = i.ano
WHERE i.nome_busca LIKE '%dias branco%'
  AND i.situacao = 'ATIVO'
ORDER BY i.ano;
```

**"Quais empresas reapresentaram o lucro líquido depois de publicado?"**
```sql
SELECT h.cnpj_cia, e.nome_empresa, YEAR(h.dt_refer) AS ano,
       COUNT(*)                         AS versoes_do_valor,
       MIN(h.valor) / 1e6               AS menor_lucro_mi,
       MAX(h.valor) / 1e6               AS maior_lucro_mi
FROM workspace.silver.dfp_contas_historico h
LEFT JOIN workspace.gold.dim_empresa e ON e.cnpj_cia = h.cnpj_cia
WHERE h.cd_conta = '3.11'
GROUP BY h.cnpj_cia, e.nome_empresa, YEAR(h.dt_refer)
HAVING COUNT(*) > 1
ORDER BY ano DESC, versoes_do_valor DESC;
```

**"Quantas empresas estão em situação crítica no último ano e por quê?"**
```sql
SELECT motivo_risco,
       COUNT(*) AS empresas
FROM workspace.gold.indicadores_financeiros
WHERE situacao = 'ATIVO'
  AND classificacao_risco = 'Crítico'
  AND ano = (SELECT MAX(ano) FROM workspace.gold.macro_anual WHERE meses_ipca = 12)
GROUP BY motivo_risco
ORDER BY empresas DESC;
```

**"Qual o ROE do Itaú (banco) nos últimos anos?"**
```sql
SELECT e.nome_empresa, e.setor, f.ano,
       ROUND(f.lucro_liquido / 1e9, 1)                                 AS lucro_bi,
       ROUND(f.patrimonio_liquido / 1e9, 1)                            AS pl_bi,
       ROUND(try_divide(f.lucro_liquido, f.patrimonio_liquido) * 100, 1) AS roe_pct
FROM workspace.gold.fato_demonstracoes f
JOIN workspace.gold.dim_empresa e ON e.cnpj_cia = f.cnpj_cia
WHERE e.nome_busca LIKE '%itau unibanco%'
  AND e.situacao = 'ATIVO'
ORDER BY f.ano;
```

## 4. Perguntas para testar (cole em *Sample questions*)

- Quantas empresas estão em situação crítica no último ano e quais os principais motivos?
- Liste as 10 empresas com maior receita que tiveram ROE abaixo do CDI em 2025.
- Qual setor tem a maior proporção de empresas que destroem valor em 2025?
- Como evoluiu o ROE mediano das empresas versus o CDI entre 2020 e 2025?
- Quais empresas saíram de Saudável em 2021 para Crítico em 2025?

## 5. Ciclo de melhoria (o que fazer quando o Genie errar)

1. Abra a resposta → **Show code** e veja o SQL gerado.
2. Se ele errou o significado de uma coluna → melhore o `COMMENT` no `gold.sql` e rode o pipeline de novo.
3. Se errou uma regra de negócio → adicione uma linha nas instruções gerais.
4. Se errou um padrão de consulta → salve o SQL correto como exemplo (passo 3).
5. Marque as respostas certas com 👍 — elas viram referência para as próximas.
6. Use **Benchmarks** do Genie com as perguntas do passo 4 e o SQL esperado para medir a precisão a cada mudança.
