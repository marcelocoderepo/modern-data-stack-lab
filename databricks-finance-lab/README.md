# Databricks Finance Lab — Radar de Saúde Financeira

Caso de uso ponta a ponta no Databricks com **dados financeiros reais e públicos**: as
demonstrações financeiras de todas as companhias abertas brasileiras (CVM) cruzadas com
Selic, CDI, IPCA e dólar (Banco Central). O objetivo é responder uma pergunta de negócio
concreta: **quais empresas estão saudáveis, quais estão em risco e quais rendem menos que a
renda fixa?**

Cobre: extração de APIs/arquivos públicos → **Lakeflow Spark Declarative Pipelines (SDP)** em
**arquitetura medalhão** → **Dashboard AI/BI** → **Genie** (perguntas em linguagem natural),
tudo versionado como **Databricks Asset Bundle**.

📄 O problema de negócio, as fontes e o dicionário de indicadores estão em [docs/CASO_DE_USO.md](docs/CASO_DE_USO.md).

## Arquitetura

```
   FONTES PÚBLICAS                      DATABRICKS (Unity Catalog: <catalog>)
 ┌──────────────────┐
 │ CVM  dados.cvm   │  ZIP/CSV   ┌───────────────────────────────────────────────────────────┐
 │  · DFP anual     │──────┐     │  Job: radar-financeiro-job (diário, 07:00)                │
 │  · Cadastro      │      │     │                                                           │
 └──────────────────┘      ├────▶│  [1] 01_extrair_fontes (notebook)                         │
 ┌──────────────────┐      │     │        │                                                  │
 │ Banco Central    │ JSON │     │        ▼                                                  │
 │  SGS: Selic, CDI │──────┘     │  Volume bronze.landing  (CSV/JSON UTF-8)                  │
 │  IPCA, Dólar     │            │        │                                                  │
 └──────────────────┘            │  [2] Pipeline SDP: radar-financeiro-sdp (serverless)      │
                                 │   ┌────────────────────────────────────────────────────┐  │
                                 │   │ BRONZE   Auto Loader → streaming tables            │  │
                                 │   │   cvm_dfp_contas · cvm_cadastro · bcb_sgs          │  │
                                 │   ├────────────────────────────────────────────────────┤  │
                                 │   │ SILVER   expectations + AUTO CDC (SCD1 / SCD2)     │  │
                                 │   │   dfp_contas · dfp_contas_historico                │  │
                                 │   │   empresas (sem PII) · bcb_series                  │  │
                                 │   ├────────────────────────────────────────────────────┤  │
                                 │   │ GOLD     materialized views (modelo dimensional)   │  │
                                 │   │   indicadores_financeiros · benchmark_setorial     │  │
                                 │   │   fato_demonstracoes · dim_empresa · macro_*       │  │
                                 │   └────────────────────────────────────────────────────┘  │
                                 │        │                                                  │
                                 │  [3] Refresh do dashboard                                 │
                                 └────────┼──────────────────────────────────────────────────┘
                                          │
                       ┌──────────────────┴──────────────────┐
                ┌──────▼────────┐                     ┌──────▼────────┐
                │ Dashboard     │                     │ Genie         │
                │ AI/BI         │                     │ "Analista de  │
                │ (comitê)      │                     │  Crédito"     │
                └───────────────┘                     └───────────────┘
```

## Recursos do Databricks e por que cada um está aqui

| Recurso | Onde | Papel no lab |
|---|---|---|
| Unity Catalog (schemas + Volume) | `resources/catalogo.yml` | Governança: `bronze`, `silver`, `gold` e a landing zone de arquivos |
| Notebook + Workflows (Jobs) | `src/extract/`, `resources/job.yml` | Extração das fontes e orquestração extrair → pipeline → dashboard |
| Auto Loader | `src/pipeline/bronze.py` | Ingestão incremental de arquivos, inclusive arquivos reescritos (reapresentações) |
| SDP — streaming tables + append flows | `bronze.py` | Uma tabela bronze alimentada por 3 fluxos (BPA, BPP, DRE) |
| SDP — expectations | `silver.py` | Qualidade: CNPJ válido, conta válida, valor presente (drop / warn / fail) |
| SDP — AUTO CDC SCD 1 e SCD 2 | `silver.py` | Versão vigente de cada conta + histórico de reapresentações da CVM |
| SDP — materialized views (SQL) | `src/pipeline/gold.sql` | Indicadores, benchmark setorial e macro, com comentários para o Genie |
| Dashboard AI/BI (Lakeview) | `src/dashboards/*.lvdash.json` | Visão do comitê de crédito: 3 páginas, filtros por ano/setor/risco |
| Genie | `genie/GENIE_SETUP.md` | Perguntas em português sobre as tabelas gold |
| Asset Bundles | `databricks.yml` | Tudo como código, deploy com um comando |

## Pré-requisitos

- Workspace Databricks com **Unity Catalog** e **serverless** — a [Free Edition](https://www.databricks.com/learn/free-edition) serve (catálogo padrão: `workspace`).
- **Databricks CLI** v0.250+ (`brew install databricks/tap/databricks`) autenticado:
  ```bash
  databricks auth login --host https://<seu-workspace>.cloud.databricks.com --profile finance-lab
  ```
- Um **SQL Warehouse** (na Free Edition já existe o *Serverless Starter Warehouse*). Pegue o ID em
  *SQL Warehouses → warehouse → Connection details* (o trecho final do HTTP path).
- Python 3.9+ local **apenas** se for extrair os dados pela sua máquina (opção B abaixo).
- Custo: na Free Edition, zero. Em workspace pago, o pipeline serverless processa ~250 MB e roda em poucos minutos.

## Instalação passo a passo

**1. Entrar na pasta do lab**
```bash
cd databricks-finance-lab
```

**2. Validar e fazer o deploy do bundle** (cria schemas, volume, pipeline, job e dashboard)
```bash
databricks bundle validate -p finance-lab --var warehouse_id=<SEU_WAREHOUSE_ID>
databricks bundle deploy   -p finance-lab --var warehouse_id=<SEU_WAREHOUSE_ID>
```
> Usando outro catálogo além de `workspace`? Acrescente `--var catalog=<seu_catalogo>` e troque
> `workspace.` por `<seu_catalogo>.` em `src/dashboards/radar_financeiro.lvdash.json`.

**3. Rodar o caso completo**

*Opção A — tudo no Databricks (recomendado se o serverless tiver acesso à internet):*
```bash
databricks bundle run -p finance-lab --var warehouse_id=<SEU_WAREHOUSE_ID> radar_financeiro_job
```

*Opção B — extrair na sua máquina e subir para o Volume* (use se a extração falhar por falta de saída
para a internet no serverless, comum na Free Edition):
```bash
python src/extract/fontes.py --dest ./landing --anos 2020-2025
```
```bash
databricks fs cp -r ./landing dbfs:/Volumes/workspace/bronze/landing -p finance-lab --overwrite
```
```bash
databricks bundle run -p finance-lab --var warehouse_id=<SEU_WAREHOUSE_ID> radar_financeiro_sdp
```
A extração local baixa ~13 MB por ano de DFP e grava ~240 MB de CSV (6 anos). Leva 2–4 minutos.

**4. Criar o espaço Genie** — siga [genie/GENIE_SETUP.md](genie/GENIE_SETUP.md) (instruções, exemplos de SQL e perguntas prontas para colar).

## Utilização

**Onde encontrar cada coisa no workspace**

| O quê | Onde |
|---|---|
| Pipeline SDP (grafo bronze → silver → gold, qualidade de dados) | *Jobs & Pipelines → radar-financeiro-sdp* |
| Job orquestrador | *Jobs & Pipelines → radar-financeiro-job* |
| Tabelas e comentários | *Catalog → workspace → bronze / silver / gold* |
| Dashboard | *Dashboards → Radar de Saúde Financeira — Companhias Abertas*, ou o link impresso por `databricks bundle summary` (o arquivo fica na pasta oculta `.bundle/radar-saude-financeira/dev/resources`) |
| Genie | *Genie → Analista de Crédito Virtual* |

**Smoke test — as camadas estão populadas?** (SQL Editor)
```sql
SELECT 'bronze.cvm_dfp_contas' AS tabela, COUNT(*) AS linhas FROM workspace.bronze.cvm_dfp_contas
UNION ALL SELECT 'silver.dfp_contas',             COUNT(*) FROM workspace.silver.dfp_contas
UNION ALL SELECT 'silver.bcb_series',             COUNT(*) FROM workspace.silver.bcb_series
UNION ALL SELECT 'gold.indicadores_financeiros',  COUNT(*) FROM workspace.gold.indicadores_financeiros
UNION ALL SELECT 'gold.benchmark_setorial',       COUNT(*) FROM workspace.gold.benchmark_setorial;
```
Referência (DFP 2020–2025, extraída em nov/2026): ~594 mil contas na silver e ~2.550 linhas em `gold.indicadores_financeiros`.

**Smoke test — os números conferem?**
```sql
SELECT nome_empresa, ano,
       ROUND(roe * 100, 1)            AS roe_pct,
       ROUND(cdi_acumulado * 100, 1)  AS cdi_pct,
       ROUND(divida_liquida_ebit, 2)  AS dl_ebit,
       classificacao_risco
FROM workspace.gold.indicadores_financeiros
WHERE nome_empresa IN ('WEG SA', 'PETROBRAS')
ORDER BY nome_empresa, ano;
```
Esperado: WEG com ROE ~30% e dívida líquida negativa (caixa líquido) em todos os anos; Petrobras
com ROE de 50,1% em 2022 caindo para 9,9% em 2024.

**Ver a qualidade de dados:** no pipeline, clique em `silver.dfp_contas` → aba *Data quality* para ver
quantas linhas cada expectation descartou.

**Testar uma reapresentação:** rode o job de novo depois de a CVM publicar uma nova versão de DFP
(acontece toda semana). O AUTO CDC atualiza `silver.dfp_contas` e acrescenta a versão anterior em
`silver.dfp_contas_historico`.

## Exercícios sugeridos

1. Incluir os **ITRs** (trimestrais, `.../DOC/ITR/DADOS/`) e calcular indicadores dos últimos 12 meses.
2. Calcular **EBITDA** somando depreciação e amortização da DFC (`DFC_MI_con`).
3. Criar um modelo de indicadores próprio para **bancos** (índice de eficiência, ROE, inadimplência).
4. Adicionar cotações (preço/lucro, dividend yield) e cruzar com o ROE.
5. Configurar um **alerta SQL** quando uma empresa da carteira mudar para "Crítico".

## Segurança e dados

- Nenhuma credencial fica no repositório: o CLI usa o perfil do `~/.databrickscfg`, e o
  `warehouse_id` é passado na linha de comando.
- As fontes são dados públicos. O cadastro da CVM traz **nome, e-mail e telefone dos diretores
  responsáveis**: eles ficam só em `bronze.cvm_cadastro` e **não** são levados para silver/gold (LGPD).
  Se quiser, restrinja o acesso ao schema `bronze` com `GRANT`/`REVOKE`.
- A pasta `landing/` (extração local) não é versionada.

## Estrutura

```
databricks.yml                     bundle (variáveis catalog, anos, warehouse_id)
resources/
  catalogo.yml                     schemas bronze/silver/gold + volume landing
  pipeline.yml                     pipeline SDP serverless
  job.yml                          job extrair → pipeline → dashboard
  dashboard.yml                    dashboard AI/BI
src/
  extract/fontes.py                extração CVM + BCB (stdlib, roda local ou no Databricks)
  extract/01_extrair_fontes.py     notebook que chama fontes.py e grava no Volume
  pipeline/bronze.py               Auto Loader → streaming tables
  pipeline/silver.py               expectations + AUTO CDC + cadastro sem PII
  pipeline/gold.sql                materialized views com indicadores e comentários
  dashboards/radar_financeiro.lvdash.json
genie/GENIE_SETUP.md               configuração do espaço Genie
docs/CASO_DE_USO.md                problema, fontes, dicionário de indicadores, resultados
```

## Autor

Marcelo Santos ([@marcelocoderepo](https://github.com/marcelocoderepo))
