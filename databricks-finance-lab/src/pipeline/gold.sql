-- =============================================================================
-- GOLD — modelo dimensional pronto para consumo (Dashboards AI/BI e Genie)
--
-- Convenções:
--   * Valores monetários em REAIS (DECIMAL 38,2).
--   * Taxas e indicadores como FRAÇÃO (0.15 = 15%) em DOUBLE.
--   * Indicadores de empresa cobrem só o modelo contábil NÃO financeiro
--     (bancos/seguradoras usam outro plano de contas na CVM).
--   * Comentários de tabela e coluna são a "documentação" que o Genie lê:
--     mantenha-os claros, em português, com a unidade de medida.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Dimensão empresa
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW gold.dim_empresa (
  cnpj_cia            STRING  COMMENT 'CNPJ da companhia aberta (formato 00.000.000/0000-00). Chave da dimensão.',
  cd_cvm              INT     COMMENT 'Código da companhia na CVM.',
  nome_empresa        STRING  COMMENT 'Nome comercial da companhia (use para exibir).',
  nome_busca          STRING  COMMENT 'Nome comercial em minúsculas e sem acentos (ITAÚ -> itau). Use para filtrar por nome: nome_busca LIKE ''%itau%''.',
  razao_social        STRING  COMMENT 'Razão social registrada na CVM.',
  setor               STRING  COMMENT 'Setor de atividade segundo a CVM (holdings agrupadas no setor da controlada). Ex.: Energia Elétrica, Bancos, Alimentos.',
  holding             BOOLEAN COMMENT 'Verdadeiro se a companhia é uma empresa de participações (holding).',
  setor_financeiro    BOOLEAN COMMENT 'Verdadeiro para bancos, seguradoras e afins (sem indicadores operacionais na gold).',
  situacao            STRING  COMMENT 'Situação do registro na CVM: ATIVO, CANCELADA, SUSPENSO etc.',
  tipo_mercado        STRING  COMMENT 'Onde os valores mobiliários são negociados: BOLSA, BALCÃO ORGANIZADO etc.',
  controle_acionario  STRING  COMMENT 'Tipo de controle: PRIVADO, ESTATAL, ESTRANGEIRO etc.',
  uf                  STRING  COMMENT 'Unidade federativa da sede.'
)
COMMENT 'Dimensão de companhias abertas brasileiras (cadastro CVM, sem dados pessoais).'
AS SELECT
  cnpj_cia AS cnpj_cia,
  cd_cvm AS cd_cvm,
  nome_comercial AS nome_empresa,
  translate(lower(nome_comercial), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') AS nome_busca,
  razao_social AS razao_social,
  setor AS setor,
  holding AS holding,
  setor_financeiro AS setor_financeiro,
  situacao AS situacao,
  tipo_mercado AS tipo_mercado,
  controle_acionario AS controle_acionario,
  uf AS uf
FROM silver.empresas;


-- -----------------------------------------------------------------------------
-- Fato: demonstrações financeiras anuais (pivot das contas-chave)
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW gold.fato_demonstracoes (
  cnpj_cia                STRING        COMMENT 'CNPJ da companhia. FK para gold.dim_empresa.',
  ano                     INT           COMMENT 'Ano do exercício social (ano da data de referência da DFP).',
  dt_refer                DATE          COMMENT 'Data de encerramento do exercício.',
  denom_cia               STRING        COMMENT 'Nome da companhia como consta no documento.',
  versao                  INT           COMMENT 'Versão do documento DFP usada (>1 indica reapresentação).',
  modelo_financeiro       BOOLEAN       COMMENT 'Verdadeiro para instituições financeiras (bancos etc.): nelas só ativo_total, patrimonio_liquido, receita_liquida, lucro_antes_ir e lucro_liquido são comparáveis; as demais contas ficam nulas.',
  ativo_total             DECIMAL(38,2) COMMENT 'Ativo total (conta 1), em reais.',
  ativo_circulante        DECIMAL(38,2) COMMENT 'Ativo circulante (conta 1.01), em reais.',
  caixa_equivalentes      DECIMAL(38,2) COMMENT 'Caixa e equivalentes de caixa (conta 1.01.01), em reais.',
  aplicacoes_financeiras  DECIMAL(38,2) COMMENT 'Aplicações financeiras de curto prazo (conta 1.01.02), em reais.',
  estoques                DECIMAL(38,2) COMMENT 'Estoques (conta 1.01.04), em reais.',
  passivo_circulante      DECIMAL(38,2) COMMENT 'Passivo circulante (conta 2.01), em reais.',
  emprestimos_cp          DECIMAL(38,2) COMMENT 'Empréstimos e financiamentos de curto prazo (conta 2.01.04), em reais.',
  passivo_nao_circulante  DECIMAL(38,2) COMMENT 'Passivo não circulante (conta 2.02), em reais.',
  emprestimos_lp          DECIMAL(38,2) COMMENT 'Empréstimos e financiamentos de longo prazo (conta 2.02.01), em reais.',
  patrimonio_liquido      DECIMAL(38,2) COMMENT 'Patrimônio líquido consolidado (2.03 no modelo geral; 2.07/2.08 em bancos), em reais. Vale para todas as empresas.',
  receita_liquida         DECIMAL(38,2) COMMENT 'Receita líquida de vendas/serviços (conta 3.01), em reais.',
  custo_vendas            DECIMAL(38,2) COMMENT 'Custo dos bens/serviços vendidos (conta 3.02), em reais (negativo).',
  resultado_bruto         DECIMAL(38,2) COMMENT 'Lucro bruto (conta 3.03), em reais.',
  ebit                    DECIMAL(38,2) COMMENT 'Resultado antes do resultado financeiro e tributos — EBIT (conta 3.05), em reais. Nulo para instituições financeiras.',
  resultado_financeiro    DECIMAL(38,2) COMMENT 'Resultado financeiro líquido (conta 3.06), em reais. Negativo = despesa financeira líquida. Nulo para instituições financeiras.',
  lucro_antes_ir          DECIMAL(38,2) COMMENT 'Resultado antes do IR/CSLL (conta "Resultado Antes dos Tributos sobre o Lucro": 3.07 no modelo geral, 3.05 em bancos), em reais.',
  lucro_liquido           DECIMAL(38,2) COMMENT 'Lucro/prejuízo consolidado do período (3.11 no modelo geral, 3.09 em bancos), em reais. Vale também para bancos e seguradoras.'
)
COMMENT 'Contas-chave do balanço e da DRE consolidados, uma linha por companhia e ano (versão mais recente da DFP).'
AS
WITH contas AS (
  SELECT
    cnpj_cia,
    dt_refer,
    ano,
    max_by(denom_cia, versao) AS denom_cia,
    MAX(versao)               AS versao,
    -- Modelo de instituição financeira: DRE de intermediação financeira OU patrimônio
    -- líquido fora da conta 2.03 (bancos usam 2.07/2.08 e 2.03 = passivos financeiros).
    MAX(CASE WHEN cd_conta = '3.01' AND lower(ds_conta) LIKE '%intermedia%financeira%' THEN 1 ELSE 0 END) = 1
      OR MAX(CASE WHEN length(cd_conta) = 4 AND cd_conta LIKE '2.%' AND cd_conta <> '2.03'
                   AND lower(ds_conta) LIKE 'patrim%nio l%quido%' THEN 1 ELSE 0 END) = 1 AS modelo_financeiro,
    SUM(CASE WHEN cd_conta = '1'       THEN valor END) AS ativo_total,
    SUM(CASE WHEN cd_conta = '1.01'    THEN valor END) AS ativo_circulante,
    SUM(CASE WHEN cd_conta = '1.01.01' THEN valor END) AS caixa_equivalentes,
    SUM(CASE WHEN cd_conta = '1.01.02' THEN valor END) AS aplicacoes_financeiras,
    SUM(CASE WHEN cd_conta = '1.01.04' THEN valor END) AS estoques,
    SUM(CASE WHEN cd_conta = '2.01'    THEN valor END) AS passivo_circulante,
    SUM(CASE WHEN cd_conta = '2.01.04' THEN valor END) AS emprestimos_cp,
    SUM(CASE WHEN cd_conta = '2.02'    THEN valor END) AS passivo_nao_circulante,
    SUM(CASE WHEN cd_conta = '2.02.01' THEN valor END) AS emprestimos_lp,
    COALESCE(
      SUM(CASE WHEN length(cd_conta) = 4 AND cd_conta LIKE '2.%' AND lower(ds_conta) LIKE 'patrim%nio l%quido%' THEN valor END),
      SUM(CASE WHEN cd_conta = '2.03' THEN valor END)) AS patrimonio_liquido,
    SUM(CASE WHEN cd_conta = '3.01'    THEN valor END) AS receita_liquida,
    SUM(CASE WHEN cd_conta = '3.02'    THEN valor END) AS custo_vendas,
    SUM(CASE WHEN cd_conta = '3.03'    THEN valor END) AS resultado_bruto,
    SUM(CASE WHEN cd_conta = '3.05'    THEN valor END) AS ebit,
    SUM(CASE WHEN cd_conta = '3.06'    THEN valor END) AS resultado_financeiro,
    -- O número da conta muda entre o modelo geral e o de bancos (ex.: lucro = 3.11 x 3.09);
    -- a descrição da conta é estável, então ela tem prioridade e o código é o fallback.
    COALESCE(
      SUM(CASE WHEN length(cd_conta) = 4 AND lower(ds_conta) LIKE 'resultado antes dos tributos%' THEN valor END),
      SUM(CASE WHEN cd_conta = '3.07' THEN valor END)) AS lucro_antes_ir,
    COALESCE(
      SUM(CASE WHEN length(cd_conta) = 4 AND lower(ds_conta) LIKE '%lucro%consolidado do per%' THEN valor END),
      SUM(CASE WHEN cd_conta = '3.11' THEN valor END)) AS lucro_liquido
  FROM silver.dfp_contas
  GROUP BY cnpj_cia, dt_refer, ano
),
-- Empresas que mudam o fim do exercício podem ter 2 DFPs no mesmo ano: fica a mais recente.
dedup AS (
  SELECT *, row_number() OVER (PARTITION BY cnpj_cia, ano ORDER BY dt_refer DESC) AS rn
  FROM contas
)
SELECT
  cnpj_cia AS cnpj_cia,
  CAST(ano AS INT) AS ano,
  dt_refer AS dt_refer,
  denom_cia AS denom_cia,
  CAST(versao AS INT) AS versao,
  modelo_financeiro AS modelo_financeiro,
  CAST(ativo_total            AS DECIMAL(38,2)) AS ativo_total,
  CAST(CASE WHEN NOT modelo_financeiro THEN ativo_circulante END AS DECIMAL(38,2)) AS ativo_circulante,
  CAST(CASE WHEN NOT modelo_financeiro THEN caixa_equivalentes END AS DECIMAL(38,2)) AS caixa_equivalentes,
  CAST(CASE WHEN NOT modelo_financeiro THEN aplicacoes_financeiras END AS DECIMAL(38,2)) AS aplicacoes_financeiras,
  CAST(CASE WHEN NOT modelo_financeiro THEN estoques END AS DECIMAL(38,2)) AS estoques,
  CAST(CASE WHEN NOT modelo_financeiro THEN passivo_circulante END AS DECIMAL(38,2)) AS passivo_circulante,
  CAST(CASE WHEN NOT modelo_financeiro THEN emprestimos_cp END AS DECIMAL(38,2)) AS emprestimos_cp,
  CAST(CASE WHEN NOT modelo_financeiro THEN passivo_nao_circulante END AS DECIMAL(38,2)) AS passivo_nao_circulante,
  CAST(CASE WHEN NOT modelo_financeiro THEN emprestimos_lp END AS DECIMAL(38,2)) AS emprestimos_lp,
  CAST(patrimonio_liquido     AS DECIMAL(38,2)) AS patrimonio_liquido,
  CAST(receita_liquida        AS DECIMAL(38,2)) AS receita_liquida,
  CAST(custo_vendas           AS DECIMAL(38,2)) AS custo_vendas,
  CAST(resultado_bruto        AS DECIMAL(38,2)) AS resultado_bruto,
  CAST(CASE WHEN NOT modelo_financeiro THEN ebit END                 AS DECIMAL(38,2)) AS ebit,
  CAST(CASE WHEN NOT modelo_financeiro THEN resultado_financeiro END AS DECIMAL(38,2)) AS resultado_financeiro,
  CAST(lucro_antes_ir         AS DECIMAL(38,2)) AS lucro_antes_ir,
  CAST(lucro_liquido          AS DECIMAL(38,2)) AS lucro_liquido
FROM dedup
WHERE rn = 1;


-- -----------------------------------------------------------------------------
-- Macro: cenário econômico anual e mensal (Banco Central)
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW gold.macro_anual (
  ano                 INT    COMMENT 'Ano-calendário.',
  selic_media         DOUBLE COMMENT 'Meta Selic média do ano, fração ao ano (0.1075 = 10,75% a.a.).',
  selic_fim_ano       DOUBLE COMMENT 'Meta Selic vigente no último dia disponível do ano, fração ao ano.',
  cdi_acumulado       DOUBLE COMMENT 'CDI acumulado no ano, fração (retorno do ativo livre de risco). Comparar com ROE.',
  ipca_acumulado      DOUBLE COMMENT 'Inflação IPCA acumulada no ano, fração (0.0483 = 4,83%).',
  meses_ipca          BIGINT COMMENT 'Quantidade de meses de IPCA disponíveis no ano (12 = ano completo).',
  dolar_medio         DOUBLE COMMENT 'Dólar PTAX venda médio do ano, em R$/US$.',
  dolar_fim_ano       DOUBLE COMMENT 'Dólar PTAX venda no último dia útil disponível do ano, em R$/US$.'
)
COMMENT 'Indicadores macroeconômicos anuais do Banco Central (SGS): Selic, CDI, IPCA e dólar.'
AS
WITH s AS (SELECT serie_id, data, valor, year(data) AS ano FROM silver.bcb_series),
selic AS (SELECT ano, AVG(valor) / 100 AS media, max_by(valor, data) / 100 AS fim FROM s WHERE serie_id = 432 GROUP BY ano),
-- Série 4389 é o CDI anualizado (base 252) de cada dia útil: acumula-se o fator diário.
cdi AS (SELECT ano, EXP(SUM(LN(1 + valor / 100) / 252)) - 1 AS acumulado FROM s WHERE serie_id = 4389 GROUP BY ano),
ipca AS (SELECT ano, EXP(SUM(LN(1 + valor / 100))) - 1 AS acumulado, COUNT(*) AS meses FROM s WHERE serie_id = 433 GROUP BY ano),
dolar AS (SELECT ano, AVG(valor) AS media, max_by(valor, data) AS fim FROM s WHERE serie_id = 1 GROUP BY ano)
SELECT
  CAST(selic.ano AS INT) AS ano,
  CAST(selic.media AS DOUBLE) AS selic_media,
  CAST(selic.fim AS DOUBLE) AS selic_fim_ano,
  CAST(cdi.acumulado AS DOUBLE) AS cdi_acumulado,
  CAST(ipca.acumulado AS DOUBLE) AS ipca_acumulado,
  CAST(ipca.meses AS BIGINT) AS meses_ipca,
  CAST(dolar.media AS DOUBLE) AS dolar_medio,
  CAST(dolar.fim AS DOUBLE) AS dolar_fim_ano
FROM selic
LEFT JOIN cdi   ON cdi.ano   = selic.ano
LEFT JOIN ipca  ON ipca.ano  = selic.ano
LEFT JOIN dolar ON dolar.ano = selic.ano;


CREATE OR REFRESH MATERIALIZED VIEW gold.macro_mensal (
  mes            DATE   COMMENT 'Primeiro dia do mês de referência.',
  selic_fim_mes  DOUBLE COMMENT 'Meta Selic no último dia disponível do mês, fração ao ano.',
  ipca_mensal    DOUBLE COMMENT 'IPCA do mês, fração (0.0042 = 0,42%).',
  ipca_12m       DOUBLE COMMENT 'IPCA acumulado em 12 meses, fração.',
  dolar_medio    DOUBLE COMMENT 'Dólar PTAX venda médio do mês, em R$/US$.'
)
COMMENT 'Série mensal de juros, inflação e câmbio para gráficos de tendência.'
AS
WITH s AS (SELECT serie_id, data, valor, CAST(date_trunc('MONTH', data) AS DATE) AS mes FROM silver.bcb_series)
SELECT
  mes AS mes,
  CAST(max_by(CASE WHEN serie_id = 432 THEN valor END, CASE WHEN serie_id = 432 THEN data END) / 100 AS DOUBLE) AS selic_fim_mes,
  CAST(MAX(CASE WHEN serie_id = 433   THEN valor END) / 100 AS DOUBLE) AS ipca_mensal,
  CAST(MAX(CASE WHEN serie_id = 13522 THEN valor END) / 100 AS DOUBLE) AS ipca_12m,
  CAST(AVG(CASE WHEN serie_id = 1     THEN valor END) AS DOUBLE) AS dolar_medio
FROM s
GROUP BY mes;


-- -----------------------------------------------------------------------------
-- Fato principal: indicadores financeiros por empresa e ano
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW gold.indicadores_financeiros (
  cnpj_cia                    STRING        COMMENT 'CNPJ da companhia. FK para gold.dim_empresa.',
  nome_empresa                STRING        COMMENT 'Nome comercial da companhia (use para exibir).',
  nome_busca                  STRING        COMMENT 'Nome em minúsculas e sem acentos. Use para filtrar por nome: nome_busca LIKE ''%weg%''.',
  setor                       STRING        COMMENT 'Setor de atividade CVM.',
  situacao                    STRING        COMMENT 'Situação do registro na CVM (ATIVO, CANCELADA...).',
  ano                         INT           COMMENT 'Ano do exercício social.',
  versao_dfp                  INT           COMMENT 'Versão da DFP usada (>1 = houve reapresentação).',
  receita_liquida             DECIMAL(38,2) COMMENT 'Receita líquida, em reais.',
  ebit                        DECIMAL(38,2) COMMENT 'EBIT (resultado operacional antes do financeiro e tributos), em reais.',
  lucro_liquido               DECIMAL(38,2) COMMENT 'Lucro líquido consolidado, em reais.',
  patrimonio_liquido          DECIMAL(38,2) COMMENT 'Patrimônio líquido consolidado no fim do ano, em reais.',
  divida_bruta                DECIMAL(38,2) COMMENT 'Empréstimos e financiamentos de curto + longo prazo, em reais.',
  caixa_total                 DECIMAL(38,2) COMMENT 'Caixa e equivalentes + aplicações financeiras de curto prazo, em reais.',
  divida_liquida              DECIMAL(38,2) COMMENT 'Dívida bruta menos caixa total, em reais. Negativa = caixa líquido.',
  margem_bruta                DOUBLE        COMMENT 'Lucro bruto / receita líquida, fração.',
  margem_ebit                 DOUBLE        COMMENT 'EBIT / receita líquida, fração.',
  margem_liquida              DOUBLE        COMMENT 'Lucro líquido / receita líquida, fração.',
  roe                         DOUBLE        COMMENT 'Retorno sobre o patrimônio: lucro líquido / PL médio (início e fim do ano), fração. Nulo se PL <= 0.',
  roa                         DOUBLE        COMMENT 'Retorno sobre ativos: lucro líquido / ativo total médio, fração.',
  roe_real                    DOUBLE        COMMENT 'ROE descontada a inflação IPCA do ano: (1+ROE)/(1+IPCA)-1, fração.',
  spread_roe_cdi              DOUBLE        COMMENT 'ROE menos CDI acumulado do ano, fração. Negativo = rendeu menos que o ativo livre de risco (destruição de valor).',
  cria_valor                  BOOLEAN       COMMENT 'Verdadeiro se o ROE superou o CDI acumulado do ano.',
  liquidez_corrente           DOUBLE        COMMENT 'Ativo circulante / passivo circulante (vezes). Abaixo de 1 = aperto de curto prazo.',
  liquidez_seca               DOUBLE        COMMENT '(Ativo circulante - estoques) / passivo circulante (vezes).',
  liquidez_imediata           DOUBLE        COMMENT 'Caixa total / passivo circulante (vezes).',
  divida_liquida_ebit         DOUBLE        COMMENT 'Alavancagem: dívida líquida / EBIT (vezes, anos de EBIT para pagar a dívida). Nulo se EBIT <= 0.',
  divida_liquida_pl           DOUBLE        COMMENT 'Dívida líquida / patrimônio líquido (vezes). Nulo se PL <= 0.',
  cobertura_financeira        DOUBLE        COMMENT 'EBIT / despesa financeira líquida (vezes). Nulo se o resultado financeiro for positivo.',
  crescimento_receita         DOUBLE        COMMENT 'Variação da receita líquida vs. ano anterior, fração (nominal).',
  crescimento_receita_real    DOUBLE        COMMENT 'Crescimento da receita descontado o IPCA, fração.',
  selic_media                 DOUBLE        COMMENT 'Meta Selic média do ano, fração ao ano (contexto macro).',
  cdi_acumulado               DOUBLE        COMMENT 'CDI acumulado do ano, fração.',
  ipca_acumulado              DOUBLE        COMMENT 'IPCA acumulado do ano, fração.',
  classificacao_risco         STRING        COMMENT 'Semáforo de saúde financeira: Crítico, Atenção ou Saudável (regras no README).',
  motivo_risco                STRING        COMMENT 'Principal motivo da classificação de risco.'
)
COMMENT 'Indicadores de rentabilidade, liquidez e endividamento das companhias abertas não financeiras, por ano, comparados com Selic/CDI/IPCA. Tabela principal do Radar de Saúde Financeira.'
AS
WITH f AS (
  SELECT
    f.*,
    LAG(ano)                OVER w AS ano_ant,
    LAG(patrimonio_liquido) OVER w AS pl_ant,
    LAG(ativo_total)        OVER w AS ativo_ant,
    LAG(receita_liquida)    OVER w AS receita_ant
  FROM gold.fato_demonstracoes f
  WINDOW w AS (PARTITION BY cnpj_cia ORDER BY ano)
),
base AS (
  SELECT
    f.*,
    e.nome_empresa,
    e.setor,
    e.situacao,
    m.selic_media,
    m.cdi_acumulado,
    m.ipca_acumulado,
    f.ano_ant = f.ano - 1 AS consecutivo,
    COALESCE(f.emprestimos_cp, 0) + COALESCE(f.emprestimos_lp, 0)               AS divida_bruta,
    COALESCE(f.caixa_equivalentes, 0) + COALESCE(f.aplicacoes_financeiras, 0)   AS caixa_total
  FROM f
  LEFT JOIN gold.dim_empresa e ON e.cnpj_cia = f.cnpj_cia
  LEFT JOIN gold.macro_anual m ON m.ano = f.ano
  WHERE NOT f.modelo_financeiro
    AND NOT COALESCE(e.setor_financeiro, FALSE)
),
calc AS (
  SELECT
    *,
    divida_bruta - caixa_total AS divida_liquida,
    CAST(CASE WHEN consecutivo AND pl_ant IS NOT NULL THEN (patrimonio_liquido + pl_ant) / 2 ELSE patrimonio_liquido END AS DOUBLE) AS pl_medio,
    CAST(CASE WHEN consecutivo AND ativo_ant IS NOT NULL THEN (ativo_total + ativo_ant) / 2 ELSE ativo_total END AS DOUBLE)        AS ativo_medio
  FROM base
),
ind AS (
  SELECT
    *,
    CASE WHEN receita_liquida > 0 THEN CAST(resultado_bruto AS DOUBLE) / CAST(receita_liquida AS DOUBLE) END AS margem_bruta,
    CASE WHEN receita_liquida > 0 THEN CAST(ebit AS DOUBLE)            / CAST(receita_liquida AS DOUBLE) END AS margem_ebit,
    CASE WHEN receita_liquida > 0 THEN CAST(lucro_liquido AS DOUBLE)   / CAST(receita_liquida AS DOUBLE) END AS margem_liquida,
    CASE WHEN pl_medio > 0        THEN CAST(lucro_liquido AS DOUBLE)   / pl_medio END                        AS roe,
    CASE WHEN ativo_medio > 0     THEN CAST(lucro_liquido AS DOUBLE)   / ativo_medio END                     AS roa,
    CASE WHEN passivo_circulante > 0 THEN CAST(ativo_circulante AS DOUBLE) / CAST(passivo_circulante AS DOUBLE) END AS liquidez_corrente,
    CASE WHEN passivo_circulante > 0 THEN CAST(ativo_circulante - COALESCE(estoques, 0) AS DOUBLE) / CAST(passivo_circulante AS DOUBLE) END AS liquidez_seca,
    CASE WHEN passivo_circulante > 0 THEN CAST(caixa_total AS DOUBLE)  / CAST(passivo_circulante AS DOUBLE) END AS liquidez_imediata,
    CASE WHEN ebit > 0               THEN CAST(divida_liquida AS DOUBLE) / CAST(ebit AS DOUBLE) END          AS divida_liquida_ebit,
    CASE WHEN patrimonio_liquido > 0 THEN CAST(divida_liquida AS DOUBLE) / CAST(patrimonio_liquido AS DOUBLE) END AS divida_liquida_pl,
    CASE WHEN resultado_financeiro < 0 THEN CAST(ebit AS DOUBLE) / CAST(-resultado_financeiro AS DOUBLE) END AS cobertura_financeira,
    CASE WHEN consecutivo AND receita_ant > 0 THEN CAST(receita_liquida AS DOUBLE) / CAST(receita_ant AS DOUBLE) - 1 END AS crescimento_receita
  FROM calc
),
final AS (
  SELECT
    *,
    (1 + roe) / (1 + ipca_acumulado) - 1                 AS roe_real,
    roe - cdi_acumulado                                  AS spread_roe_cdi,
    (1 + crescimento_receita) / (1 + ipca_acumulado) - 1 AS crescimento_receita_real,
    -- Semáforo: regras simples e auditáveis, pensadas para triagem (não substituem análise de crédito).
    CASE
      WHEN patrimonio_liquido <= 0                                   THEN 'Crítico'
      WHEN ebit <= 0 AND divida_liquida > 0                          THEN 'Crítico'
      WHEN liquidez_corrente < 1 AND divida_liquida_ebit > 4         THEN 'Crítico'
      WHEN divida_liquida_ebit > 3                                   THEN 'Atenção'
      WHEN liquidez_corrente < 1                                     THEN 'Atenção'
      WHEN cobertura_financeira < 1.5                                THEN 'Atenção'
      WHEN roe < cdi_acumulado                                       THEN 'Atenção'
      ELSE 'Saudável'
    END AS classificacao_risco,
    CASE
      WHEN patrimonio_liquido <= 0                                   THEN 'Patrimônio líquido negativo'
      WHEN ebit <= 0 AND divida_liquida > 0                          THEN 'Prejuízo operacional com dívida líquida'
      WHEN liquidez_corrente < 1 AND divida_liquida_ebit > 4         THEN 'Iliquidez + alavancagem acima de 4x EBIT'
      WHEN divida_liquida_ebit > 3                                   THEN 'Alavancagem acima de 3x EBIT'
      WHEN liquidez_corrente < 1                                     THEN 'Liquidez corrente abaixo de 1'
      WHEN cobertura_financeira < 1.5                                THEN 'EBIT cobre menos de 1,5x a despesa financeira'
      WHEN roe < cdi_acumulado                                       THEN 'ROE abaixo do CDI'
      ELSE 'Sem alertas'
    END AS motivo_risco
  FROM ind
)
SELECT
  cnpj_cia AS cnpj_cia,
  COALESCE(nome_empresa, denom_cia) AS nome_empresa,
  translate(lower(COALESCE(nome_empresa, denom_cia)), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc') AS nome_busca,
  COALESCE(setor, 'Não informado') AS setor,
  situacao AS situacao,
  CAST(ano AS INT) AS ano,
  CAST(versao AS INT) AS versao_dfp,
  CAST(receita_liquida    AS DECIMAL(38,2)) AS receita_liquida,
  CAST(ebit               AS DECIMAL(38,2)) AS ebit,
  CAST(lucro_liquido      AS DECIMAL(38,2)) AS lucro_liquido,
  CAST(patrimonio_liquido AS DECIMAL(38,2)) AS patrimonio_liquido,
  CAST(divida_bruta       AS DECIMAL(38,2)) AS divida_bruta,
  CAST(caixa_total        AS DECIMAL(38,2)) AS caixa_total,
  CAST(divida_liquida     AS DECIMAL(38,2)) AS divida_liquida,
  CAST(margem_bruta             AS DOUBLE) AS margem_bruta,
  CAST(margem_ebit              AS DOUBLE) AS margem_ebit,
  CAST(margem_liquida           AS DOUBLE) AS margem_liquida,
  CAST(roe                      AS DOUBLE) AS roe,
  CAST(roa                      AS DOUBLE) AS roa,
  CAST(roe_real                 AS DOUBLE) AS roe_real,
  CAST(spread_roe_cdi           AS DOUBLE) AS spread_roe_cdi,
  roe > cdi_acumulado AS cria_valor,
  CAST(liquidez_corrente        AS DOUBLE) AS liquidez_corrente,
  CAST(liquidez_seca            AS DOUBLE) AS liquidez_seca,
  CAST(liquidez_imediata        AS DOUBLE) AS liquidez_imediata,
  CAST(divida_liquida_ebit      AS DOUBLE) AS divida_liquida_ebit,
  CAST(divida_liquida_pl        AS DOUBLE) AS divida_liquida_pl,
  CAST(cobertura_financeira     AS DOUBLE) AS cobertura_financeira,
  CAST(crescimento_receita      AS DOUBLE) AS crescimento_receita,
  CAST(crescimento_receita_real AS DOUBLE) AS crescimento_receita_real,
  CAST(selic_media              AS DOUBLE) AS selic_media,
  CAST(cdi_acumulado            AS DOUBLE) AS cdi_acumulado,
  CAST(ipca_acumulado           AS DOUBLE) AS ipca_acumulado,
  classificacao_risco AS classificacao_risco,
  motivo_risco AS motivo_risco
FROM final;


-- -----------------------------------------------------------------------------
-- Agregado setorial (benchmark para comparar uma empresa com seus pares)
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW gold.benchmark_setorial (
  setor                       STRING        COMMENT 'Setor de atividade CVM.',
  ano                         INT           COMMENT 'Ano do exercício social.',
  qtd_empresas                BIGINT        COMMENT 'Número de companhias com DFP no setor e ano.',
  receita_total               DECIMAL(38,2) COMMENT 'Soma da receita líquida do setor, em reais.',
  lucro_total                 DECIMAL(38,2) COMMENT 'Soma do lucro líquido do setor, em reais.',
  roe_mediano                 DOUBLE        COMMENT 'Mediana do ROE das empresas do setor, fração.',
  margem_ebit_mediana         DOUBLE        COMMENT 'Mediana da margem EBIT, fração.',
  divida_liquida_ebit_mediana DOUBLE        COMMENT 'Mediana da alavancagem dívida líquida/EBIT, vezes.',
  liquidez_corrente_mediana   DOUBLE        COMMENT 'Mediana da liquidez corrente, vezes.',
  pct_cria_valor              DOUBLE        COMMENT 'Fração das empresas do setor com ROE acima do CDI.',
  pct_critico                 DOUBLE        COMMENT 'Fração das empresas do setor classificadas como Crítico.'
)
COMMENT 'Benchmark por setor e ano: medianas dos indicadores e proporção de empresas que criam valor ou estão em risco.'
AS SELECT
  setor AS setor,
  ano AS ano,
  CAST(COUNT(*) AS BIGINT) AS qtd_empresas,
  CAST(SUM(receita_liquida) AS DECIMAL(38,2)) AS receita_total,
  CAST(SUM(lucro_liquido)   AS DECIMAL(38,2)) AS lucro_total,
  CAST(percentile_approx(roe, 0.5)                 AS DOUBLE) AS roe_mediano,
  CAST(percentile_approx(margem_ebit, 0.5)         AS DOUBLE) AS margem_ebit_mediana,
  CAST(percentile_approx(divida_liquida_ebit, 0.5) AS DOUBLE) AS divida_liquida_ebit_mediana,
  CAST(percentile_approx(liquidez_corrente, 0.5)   AS DOUBLE) AS liquidez_corrente_mediana,
  CAST(AVG(CASE WHEN cria_valor THEN 1.0 ELSE 0.0 END) AS DOUBLE) AS pct_cria_valor,
  CAST(AVG(CASE WHEN classificacao_risco = 'Crítico' THEN 1.0 ELSE 0.0 END) AS DOUBLE) AS pct_critico
FROM gold.indicadores_financeiros
GROUP BY setor, ano;
