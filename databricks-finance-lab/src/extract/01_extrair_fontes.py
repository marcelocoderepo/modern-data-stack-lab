# Databricks notebook source
# MAGIC %md
# MAGIC # 01 · Extração das fontes (CVM + Banco Central) → Volume `landing`
# MAGIC
# MAGIC Baixa os dados públicos e grava na landing zone do Unity Catalog, onde o
# MAGIC pipeline SDP (Auto Loader) vai ler de forma incremental.
# MAGIC
# MAGIC | Fonte | O quê | Formato na landing |
# MAGIC |---|---|---|
# MAGIC | CVM — Cadastro | setor, situação e mercado de cada companhia | CSV `;` UTF-8 |
# MAGIC | CVM — DFP | Balanço (ativo/passivo) e DRE consolidados, anuais | CSV `;` UTF-8 |
# MAGIC | BCB — SGS | Selic, CDI, IPCA, dólar PTAX | JSON lines |
# MAGIC
# MAGIC > **Free Edition:** se o serverless não tiver saída para a internet, rode
# MAGIC > `python src/extract/fontes.py` na sua máquina e suba a pasta com
# MAGIC > `databricks fs cp -r ./landing dbfs:/Volumes/<catalog>/bronze/landing` (veja o README).

# COMMAND ----------

dbutils.widgets.text("catalog", "workspace", "Catálogo UC")
dbutils.widgets.text("anos", "2020-2025", "Anos da DFP (ex.: 2020-2025)")

catalog = dbutils.widgets.get("catalog")
anos_txt = dbutils.widgets.get("anos")
dest = f"/Volumes/{catalog}/bronze/landing"
print(f"Destino: {dest} | anos: {anos_txt}")

# COMMAND ----------

# O notebook roda na própria pasta (workspace files), então o módulo é importável direto.
from fontes import extrair_tudo, parse_anos

resumo = extrair_tudo(dest, parse_anos(anos_txt))

# COMMAND ----------

# Falha o job se nada foi extraído da DFP (evita rodar o pipeline em cima de landing vazia).
if not resumo["dfp"]:
    raise RuntimeError(f"Nenhum arquivo DFP extraído. Erros: {resumo['erros']}")

display(dbutils.fs.ls(f"{dest}/cvm/dfp/DRE_con"))
