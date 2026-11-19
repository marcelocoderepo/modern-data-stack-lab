"""
BRONZE — dados crus, como chegaram da fonte, + metadados de ingestão.

Regras da camada:
  * Tudo como STRING (nenhuma interpretação de tipo aqui — isso é papel da silver).
  * Ingestão incremental com Auto Loader (streaming tables): cada arquivo novo ou
    sobrescrito na landing é processado uma única vez.
  * Colunas técnicas: _arquivo (origem) e _ingerido_em (quando entrou no lakehouse).
"""

from pyspark import pipelines as dp
from pyspark.sql import functions as F

LANDING = spark.conf.get("landing_path")  # ex.: /Volumes/workspace/bronze/landing

COLUNAS_DFP = [
    "CNPJ_CIA", "DT_REFER", "VERSAO", "DENOM_CIA", "CD_CVM", "GRUPO_DFP", "MOEDA",
    "ESCALA_MOEDA", "ORDEM_EXERC", "DT_INI_EXERC", "DT_FIM_EXERC", "CD_CONTA",
    "DS_CONTA", "VL_CONTA", "ST_CONTA_FIXA",
]


def _auto_loader(caminho: str, formato: str, **opcoes):
    leitor = (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", formato)
        .option("cloudFiles.inferColumnTypes", "false")
        # A CVM republica o arquivo do ano quando há reapresentação, e o BCB
        # cresce o arquivo do ano corrente: reprocessamos arquivos sobrescritos.
        .option("cloudFiles.allowOverwrites", "true")
    )
    for k, v in opcoes.items():
        leitor = leitor.option(k, v)
    return leitor.load(caminho)


def _metadados(df):
    return df.withColumn("_arquivo", F.col("_metadata.file_path")).withColumn(
        "_ingerido_em", F.current_timestamp()
    )


# --------------------------------------------------------------------------- #
# CVM · DFP — uma streaming table alimentada por 3 flows (BPA, BPP, DRE)
# --------------------------------------------------------------------------- #
dp.create_streaming_table(
    name="bronze.cvm_dfp_contas",
    comment="Linhas cruas das DFPs da CVM (Balanço Ativo, Passivo e DRE consolidados), "
    "uma linha por empresa x versão x exercício x conta contábil.",
    table_properties={"quality": "bronze"},
)


def _registrar_flow_dfp(demonstracao: str) -> None:
    @dp.append_flow(target="bronze.cvm_dfp_contas", name=f"ingestao_dfp_{demonstracao.lower()}")
    def _flow():
        df = _auto_loader(f"{LANDING}/cvm/dfp/{demonstracao}/", "csv", header="true", sep=";")
        # Balanços não têm DT_INI_EXERC (são posição numa data); a DRE tem (é período).
        if "DT_INI_EXERC" not in df.columns:
            df = df.withColumn("DT_INI_EXERC", F.lit(None).cast("string"))
        return _metadados(
            df.select(*COLUNAS_DFP).withColumn("DEMONSTRACAO", F.lit(demonstracao))
        )


for _dem in ["BPA_con", "BPP_con", "DRE_con"]:
    _registrar_flow_dfp(_dem)


# --------------------------------------------------------------------------- #
# CVM · Cadastro — é um snapshot completo, então MV (recalcula a cada refresh)
# --------------------------------------------------------------------------- #
@dp.materialized_view(
    name="bronze.cvm_cadastro",
    comment="Snapshot cru do cadastro de companhias abertas da CVM. Contém dados pessoais "
    "de responsáveis (nome, e-mail, telefone) que NÃO são propagados para a silver (LGPD).",
    table_properties={"quality": "bronze"},
)
def cvm_cadastro():
    return _metadados(
        spark.read.option("header", "true").option("sep", ";")
        .csv(f"{LANDING}/cvm/cadastro/")
    )


# --------------------------------------------------------------------------- #
# BCB · SGS — JSON lines com uma observação por linha
# --------------------------------------------------------------------------- #
@dp.table(
    name="bronze.bcb_sgs",
    comment="Observações cruas das séries temporais do SGS/Banco Central (Selic, CDI, IPCA, dólar).",
    table_properties={"quality": "bronze"},
)
def bcb_sgs():
    return _metadados(_auto_loader(f"{LANDING}/bcb/sgs/", "json"))
