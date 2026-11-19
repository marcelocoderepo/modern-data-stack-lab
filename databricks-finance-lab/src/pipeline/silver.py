"""
SILVER — dados limpos, tipados, deduplicados e com qualidade garantida.

Destaques de SDP usados aqui:
  * Expectations (expect / expect_or_drop / expect_or_fail) para qualidade.
  * AUTO CDC (SCD tipo 1) para resolver REAPRESENTAÇÕES da CVM: quando a empresa
    reenvia a DFP com VERSAO maior, a versão nova sobrescreve a antiga.
  * AUTO CDC (SCD tipo 2) mantendo o HISTÓRICO das reapresentações — permite
    responder "quais empresas mudaram o lucro depois de publicado?".
  * Materialized view para o cadastro, removendo dados pessoais (LGPD).
"""

from pyspark import pipelines as dp
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# Setores cujo plano de contas da CVM é diferente do modelo "comercial/industrial"
# (bancos, seguradoras etc.). Indicadores como margem bruta e liquidez corrente
# não fazem sentido para eles — são marcados e tratados à parte na gold.
SETORES_FINANCEIROS = [
    "Bancos", "Intermediação Financeira", "Seguradoras e Corretoras",
    "Arrendamento Mercantil", "Securitização de Recebíveis", "Crédito Imobiliário",
    "Bolsas de Valores/Mercadorias e Futuros", "Factoring",
]

# Holdings usam nomes abreviados no cadastro da CVM; sem isso, o mesmo setor
# aparece duas vezes nos rankings ("Const. Civil..." vs "Construção Civil...").
SETORES_SINONIMOS = {
    "Const. Civil, Mat. Const. e Decoração": "Construção Civil, Mat. Constr. e Decoração",
    "Máqs., Equip., Veíc. e Peças": "Máquinas, Equipamentos, Veículos e Peças",
    "Serviços médicos": "Serviços Médicos",
    "Sem Setor Principal": "Emp. Adm. Participações",
}


# --------------------------------------------------------------------------- #
# DFP · contas contábeis
# --------------------------------------------------------------------------- #
@dp.view(name="dfp_contas_preparadas", comment="Bronze DFP tipada e filtrada (view intermediária).")
@dp.expect_or_drop("cnpj_valido", "cnpj_cia RLIKE '^[0-9]{2}[.][0-9]{3}[.][0-9]{3}/[0-9]{4}-[0-9]{2}$'")
@dp.expect_or_drop("conta_valida", "cd_conta RLIKE '^[1-3]([.][0-9]{2})*$'")
@dp.expect_or_drop("valor_presente", "valor IS NOT NULL")
@dp.expect_or_drop("data_referencia_presente", "dt_refer IS NOT NULL")
@dp.expect("moeda_real", "moeda = 'REAL'")
def dfp_contas_preparadas():
    fator_escala = F.when(F.col("ESCALA_MOEDA") == "MIL", F.lit(1000)).otherwise(F.lit(1))
    return (
        spark.readStream.table("bronze.cvm_dfp_contas")
        # ÚLTIMO = exercício atual do documento. PENÚLTIMO é só o comparativo do ano
        # anterior; cada ano é lido do seu próprio documento.
        .where(F.col("ORDEM_EXERC") == "ÚLTIMO")
        .select(
            F.col("CNPJ_CIA").alias("cnpj_cia"),
            F.col("CD_CVM").cast("int").alias("cd_cvm"),
            F.trim("DENOM_CIA").alias("denom_cia"),
            F.to_date("DT_REFER").alias("dt_refer"),
            F.year(F.to_date("DT_REFER")).alias("ano"),
            F.col("VERSAO").cast("int").alias("versao"),
            F.col("DEMONSTRACAO").alias("demonstracao"),
            F.col("MOEDA").alias("moeda"),
            F.col("CD_CONTA").alias("cd_conta"),
            F.trim("DS_CONTA").alias("ds_conta"),
            (F.col("VL_CONTA").cast("decimal(38,10)") * fator_escala)
            .cast("decimal(38,2)")
            .alias("valor"),
            (F.col("ST_CONTA_FIXA") == "S").alias("conta_fixa"),
            "_arquivo",
            "_ingerido_em",
        )
    )


# SCD 1 — "a versão vigente" de cada conta: é o que os indicadores consomem.
dp.create_streaming_table(
    name="silver.dfp_contas",
    comment="Contas das DFPs consolidadas na versão mais recente (reapresentações aplicadas). "
    "Chave: cnpj_cia + dt_refer + cd_conta. Valores em reais (escala MIL já convertida).",
    table_properties={"quality": "silver"},
)
dp.create_auto_cdc_flow(
    target="silver.dfp_contas",
    source="dfp_contas_preparadas",
    keys=["cnpj_cia", "dt_refer", "cd_conta"],
    sequence_by=F.struct("versao", "_ingerido_em"),
    stored_as_scd_type=1,
)

# SCD 2 — histórico de valores por versão (auditoria de reapresentações).
dp.create_streaming_table(
    name="silver.dfp_contas_historico",
    comment="Histórico SCD tipo 2 das contas: uma linha por valor distinto que a conta já teve "
    "(__START_AT/__END_AT pela versão do documento). Use para estudar reapresentações.",
    table_properties={"quality": "silver"},
)
dp.create_auto_cdc_flow(
    target="silver.dfp_contas_historico",
    source="dfp_contas_preparadas",
    keys=["cnpj_cia", "dt_refer", "cd_conta"],
    sequence_by=F.struct("versao", "_ingerido_em"),
    stored_as_scd_type=2,
    track_history_column_list=["valor"],
)


# --------------------------------------------------------------------------- #
# Cadastro de empresas (sem dados pessoais)
# --------------------------------------------------------------------------- #
@dp.materialized_view(
    name="silver.empresas",
    comment="Uma linha por CNPJ com o registro cadastral mais recente da CVM. "
    "Somente atributos da empresa — dados pessoais de responsáveis foram descartados (LGPD).",
    table_properties={"quality": "silver"},
)
@dp.expect_or_fail("cnpj_unico_nao_nulo", "cnpj_cia IS NOT NULL")
def empresas():
    setor_bruto = F.coalesce(F.trim("SETOR_ATIV"), F.lit("Não informado"))
    # "Emp. Adm. Part. - Energia Elétrica" (holding) -> "Energia Elétrica"
    setor = F.regexp_replace(setor_bruto, r"^Emp\. Adm\. Part\. ?- ?", "")
    for abreviado, oficial in SETORES_SINONIMOS.items():
        setor = F.when(setor == abreviado, F.lit(oficial)).otherwise(setor)
    janela = Window.partitionBy("CNPJ_CIA").orderBy(
        (F.col("SIT") == "ATIVO").desc(), F.to_date("DT_REG").desc_nulls_last()
    )
    return (
        spark.read.table("bronze.cvm_cadastro")
        .withColumn("_rn", F.row_number().over(janela))
        .where("_rn = 1")
        .select(
            F.col("CNPJ_CIA").alias("cnpj_cia"),
            F.col("CD_CVM").cast("int").alias("cd_cvm"),
            F.trim("DENOM_SOCIAL").alias("razao_social"),
            F.coalesce(F.trim("DENOM_COMERC"), F.trim("DENOM_SOCIAL")).alias("nome_comercial"),
            setor.alias("setor"),
            setor_bruto.startswith("Emp. Adm. Part.").alias("holding"),
            setor.isin(SETORES_FINANCEIROS).alias("setor_financeiro"),
            F.col("SIT").alias("situacao"),
            F.col("TP_MERC").alias("tipo_mercado"),
            F.col("CATEG_REG").alias("categoria_registro"),
            F.col("CONTROLE_ACIONARIO").alias("controle_acionario"),
            F.col("UF").alias("uf"),
            F.to_date("DT_REG").alias("dt_registro"),
            F.to_date("DT_CANCEL").alias("dt_cancelamento"),
        )
    )


# --------------------------------------------------------------------------- #
# Banco Central · séries temporais
# --------------------------------------------------------------------------- #
@dp.view(name="bcb_sgs_preparadas", comment="Bronze SGS tipada (view intermediária).")
@dp.expect_or_drop("data_valida", "data IS NOT NULL")
@dp.expect_or_drop("valor_valido", "valor IS NOT NULL")
def bcb_sgs_preparadas():
    return spark.readStream.table("bronze.bcb_sgs").select(
        F.col("serie_id").cast("int").alias("serie_id"),
        F.col("serie_nome"),
        F.col("unidade"),
        F.col("periodicidade"),
        F.to_date("data", "dd/MM/yyyy").alias("data"),
        F.col("valor").cast("double").alias("valor"),
        "_ingerido_em",
    )


dp.create_streaming_table(
    name="silver.bcb_series",
    comment="Séries do Banco Central em formato longo (uma linha por série x data). "
    "Valores revisados pelo BCB são atualizados via AUTO CDC.",
    table_properties={"quality": "silver"},
)
dp.create_auto_cdc_flow(
    target="silver.bcb_series",
    source="bcb_sgs_preparadas",
    keys=["serie_id", "data"],
    sequence_by="_ingerido_em",
    stored_as_scd_type=1,
)
