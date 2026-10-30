-- =====================================================================================
-- INDUSTRIAL LOSS ATTRIBUTION & SLITTING RECONCILIATION ENGINE
-- Dialeto: Oracle SQL
-- Objetivo: Rastrear desvios de processo (Perda 33 / Balanço de Massa), equalizar
--           pistas de corte (slitting) e ratear perdas proporcionalmente aos insumos.
-- =====================================================================================

WITH ops_no_periodo AS (
    -- 0. CTE SEMENTE (Performance Optimization):
    -- Isola as Ordens de Produção (OPs) com apontamentos de refugo automático no período,
    -- direcionando a leitura de índices e evitando scans completos em tabelas históricas.
    SELECT DISTINCT
        p.id_empresa,
        p.id_ordem_producao,
        pop.id_produto,
        pop.nr_versao
    FROM erp_producao.fato_apontamento_perda p
    INNER JOIN erp_producao.fato_ordem_producao pop 
        ON pop.id_empresa = p.id_empresa 
       AND pop.id_ordem_producao = p.id_ordem_producao
    WHERE p.id_empresa = 1
      AND p.cd_tipo_perda = 33 -- 33: Refugo Oculto / Ajuste de Balanço de Massa
      AND p.dt_registro >= TO_DATE('2026-10-01', 'YYYY-MM-DD')
      AND p.dt_registro <  TO_DATE('2026-11-01', 'YYYY-MM-DD')
),

itens_elegiveis AS (
    -- 0.1. Mapeia estritamente os SKUs de PA e insumos consumidos nas OPs selecionadas
    SELECT DISTINCT id_empresa, id_produto AS cd_item FROM ops_no_periodo
    UNION
    SELECT DISTINCT c.id_empresa, c.id_material AS cd_item
    FROM erp_producao.ordem_producao_componente c
    INNER JOIN ops_no_periodo op 
        ON op.id_empresa = c.id_empresa 
       AND op.id_ordem_producao = c.id_ordem_producao
),

cad_classificacao_item AS (
    -- 0.2. Dimensão Cadastral de Produtos e Insumos com tratamento de hierarquia e nulos
    SELECT 
        i.id_empresa,
        i.cd_item,
        i.ds_item,
        i.nm_marca_fornecedor,
        i.cd_tipo_ficha_tecnica,
        i.cd_grupo,
        g.ds_grupo,
        i.cd_subgrupo,
        sg.ds_subgrupo,
        NVL(TO_CHAR(i.cd_classe_produto), 'Sem Classe') AS cd_classe_produto,
        NVL(cl.ds_classe, 'Sem Classe')                AS ds_classe_produto,
        NVL(TO_CHAR(i.cd_familia), 'Sem Familia')       AS cd_familia,
        NVL(f.ds_familia, 'Sem Familia')               AS ds_familia
    FROM erp_estoque.dim_item i
    INNER JOIN itens_elegiveis ie 
        ON ie.id_empresa = i.id_empresa 
       AND ie.cd_item = i.cd_item
    INNER JOIN erp_estoque.dim_grupo g 
        ON g.id_empresa = i.id_empresa 
       AND g.cd_grupo = i.cd_grupo
    INNER JOIN erp_estoque.dim_subgrupo sg 
        ON sg.id_empresa = i.id_empresa 
       AND sg.cd_grupo = i.cd_grupo 
       AND sg.cd_subgrupo = i.cd_subgrupo
    LEFT JOIN erp_estoque.dim_classe cl 
        ON cl.id_empresa = i.id_empresa 
       AND cl.cd_classe = i.cd_classe_produto
    LEFT JOIN erp_estoque.dim_familia f 
        ON f.id_empresa = i.id_empresa 
       AND f.cd_familia = i.cd_familia
    WHERE i.id_empresa = 1
),

perda_prevista_op AS (
    -- 1. Descobre a perda teórica estimada pela engenharia e o número de pistas (slitting)
    SELECT 
        op.id_empresa,
        op.id_ordem_producao,
        op.id_produto,
        op.nr_versao,
        ROUND(pop.qt_planejada * SUM(c.qt_aplicada_unitaria), 2) AS vl_volume_teorico_limpo,
        ROUND(SUM(c.qt_total_aplicada) - (pop.qt_planejada * SUM(c.qt_aplicada_unitaria)), 2) AS vl_perda_estimada_op,
        ROUND(
            (SUM(c.qt_total_aplicada) - (pop.qt_planejada * SUM(c.qt_aplicada_unitaria))) 
            / NULLIF(pop.qt_planejada * SUM(c.qt_aplicada_unitaria), 0), 
            4
        ) AS vl_perc_perda_dinamica,
        NVL(MAX(TO_NUMBER(
            erp_engenharia.f_extrai_parametro_ficha(
                op.id_empresa, op.id_produto, op.nr_versao, op.id_ordem_producao, 
                CASE cpa.cd_tipo_ficha_tecnica 
                    WHEN 1 THEN 222 
                    WHEN 4 THEN 224 
                    WHEN 5 THEN 264 
                    ELSE 224 
                END
            )
        )), 1) AS nr_pistas_corte
    FROM ops_no_periodo op
    INNER JOIN erp_producao.fato_ordem_producao pop 
        ON pop.id_empresa = op.id_empresa 
       AND pop.id_ordem_producao = op.id_ordem_producao
    INNER JOIN cad_classificacao_item cpa 
        ON cpa.id_empresa = op.id_empresa 
       AND cpa.cd_item = op.id_produto
    INNER JOIN erp_producao.ordem_producao_componente c 
        ON c.id_empresa = op.id_empresa 
       AND c.id_ordem_producao = op.id_ordem_producao
    INNER JOIN erp_producao.ordem_producao_grupo_comp gc 
        ON gc.id_empresa = c.id_empresa 
       AND gc.id_ordem_producao = c.id_ordem_producao 
       AND gc.id_seq_grupo = c.id_seq_grupo
    WHERE gc.ds_grupo_componente LIKE '%MATERIA PRIMA%'
    GROUP BY op.id_empresa, op.id_ordem_producao, op.id_produto, op.nr_versao, pop.qt_planejada
),

consumo_componentes_op AS (
    -- 2. Consumo acumulado histórico por componente e cálculo da fração proporcional de carga
    SELECT 
        c.id_empresa,
        c.id_ordem_producao,
        c.id_material AS cd_componente,
        ccomp.ds_item AS ds_componente,
        ccomp.nm_marca_fornecedor AS fornecedor_componente,
        ccomp.cd_grupo AS cd_grupo_componente,
        ccomp.ds_grupo AS ds_grupo_componente,
        ccomp.cd_subgrupo AS cd_subgrupo_comp,
        ccomp.ds_subgrupo AS ds_subgrupo_comp,
        ccomp.ds_classe_produto AS ds_classe_comp,
        ccomp.ds_familia AS ds_familia_comp,
        SUM(c.qt_total_aplicada) AS vl_consumo_total_componente,
        SUM(SUM(c.qt_total_aplicada)) OVER (
            PARTITION BY c.id_empresa, c.id_ordem_producao
        ) AS vl_consumo_total_op,
        ROUND(
            SUM(c.qt_total_aplicada) / NULLIF(SUM(SUM(c.qt_total_aplicada)) OVER (PARTITION BY c.id_empresa, c.id_ordem_producao), 0),
            6
        ) AS vl_proporcao_consumo
    FROM erp_producao.ordem_producao_componente c
    INNER JOIN ops_no_periodo op 
        ON op.id_empresa = c.id_empresa 
       AND op.id_ordem_producao = c.id_ordem_producao
    INNER JOIN cad_classificacao_item ccomp 
        ON ccomp.id_empresa = c.id_empresa 
       AND ccomp.cd_item = c.id_material
    WHERE c.nr_seq_aplicacao IS NOT NULL
      AND ccomp.cd_grupo IN (1, 2) -- Grupos de Matéria-Prima Principal (Filmes / Substratos)
    GROUP BY 
        c.id_empresa, c.id_ordem_producao, c.id_material, ccomp.ds_item, 
        ccomp.nm_marca_fornecedor, ccomp.cd_grupo, ccomp.ds_grupo, 
        ccomp.cd_subgrupo, ccomp.ds_subgrupo, ccomp.ds_classe_produto, ccomp.ds_familia
),

agg_producao AS (
    -- Agrega toda a produção real das OPs sem limitar por data da etapa
    SELECT 
        prd.id_empresa,
        prd.id_ordem_producao,
        prd.cd_etapa,
        SUM(prd.qt_produzida) AS qt_produzida,
        MAX(prd.id_recurso)   AS id_recurso
    FROM erp_producao.fato_apontamento_producao prd
    INNER JOIN ops_no_periodo op 
        ON op.id_empresa = prd.id_empresa 
       AND op.id_ordem_producao = prd.id_ordem_producao
    GROUP BY prd.id_empresa, prd.id_ordem_producao, prd.cd_etapa
),

agg_perda AS (
    -- Segrega o refugo direto de máquina da perda de balanço automático (Tipo 33)
    SELECT 
        per.id_empresa,
        per.id_ordem_producao,
        per.cd_etapa,
        SUM(CASE WHEN per.cd_tipo_perda NOT IN (1, 2, 33) THEN per.qt_perda ELSE 0 END) AS qt_perda_operador,
        SUM(CASE WHEN per.cd_tipo_perda = 33 THEN per.qt_perda ELSE 0 END)              AS qt_perda_sistema_33,
        SUM(CASE WHEN per.cd_tipo_perda NOT IN (1, 2) THEN per.qt_perda ELSE 0 END)     AS qt_total_perda_registrada
    FROM erp_producao.fato_apontamento_perda per
    INNER JOIN ops_no_periodo op 
        ON op.id_empresa = per.id_empresa 
       AND op.id_ordem_producao = per.id_ordem_producao
    GROUP BY per.id_empresa, per.id_ordem_producao, per.cd_etapa
),

producao_etapa AS (
    -- 3. Consolidação 1:1 por Roteiro Operacional
    SELECT 
        pe.id_empresa,
        pe.id_ordem_producao,
        pet.nr_seq_etapa,
        pet.cd_etapa,
        NVL(prd.qt_produzida, 0)             AS qt_produzida,
        NVL(per.qt_perda_operador, 0)         AS qt_perda_operador,
        NVL(per.qt_perda_sistema_33, 0)       AS qt_perda_sistema_33,
        NVL(per.qt_total_perda_registrada, 0) AS qt_total_perda_registrada,
        prd.id_recurso                        AS id_recurso, 
        pe.id_produto, 
        pe.nr_versao
    FROM ops_no_periodo pe
    INNER JOIN erp_producao.ordem_producao_etapa pet 
        ON pet.id_empresa = pe.id_empresa AND pet.id_ordem_producao = pe.id_ordem_producao
    INNER JOIN erp_producao.dim_etapa_operacao et 
        ON et.id_empresa = pet.id_empresa AND et.cd_etapa = pet.cd_etapa AND et.fl_retrabalho = 'N'
    LEFT JOIN agg_producao prd 
        ON prd.id_empresa = pet.id_empresa AND prd.id_ordem_producao = pet.id_ordem_producao AND prd.cd_etapa = pet.cd_etapa
    LEFT JOIN agg_perda per 
        ON per.id_empresa = pet.id_empresa AND per.id_ordem_producao = pet.id_ordem_producao AND per.cd_etapa = pet.cd_etapa
),

fator_conversao AS (
    -- 4. Coeficiente técnico para conversão de unidade final (ex: metros para milheiros)
    SELECT 
        pe.id_empresa,
        pe.id_ordem_producao,
        pe.nr_seq_etapa,
        MAX(comp.qt_aplicada_unitaria) AS vl_fator_conversao
    FROM producao_etapa pe
    LEFT JOIN erp_engenharia.ficha_tecnica_componente comp 
        ON comp.id_empresa = pe.id_empresa 
       AND comp.cd_composicao = pe.id_produto || '/' || pe.nr_versao 
       AND comp.nr_seq_aplicacao = 1
    LEFT JOIN erp_engenharia.ficha_tecnica_grupo_comp gc 
        ON gc.id_empresa = comp.id_empresa 
       AND gc.cd_composicao = comp.cd_composicao 
       AND gc.id_seq_grupo = comp.id_seq_grupo 
       AND gc.ds_grupo LIKE '%MATERIA PRIMA%'
    GROUP BY pe.id_empresa, pe.id_ordem_producao, pe.nr_seq_etapa
),

etapa_sequenciada AS (
    -- 5. Numeração cronológica de etapas (permite evitar aninhamento de funções analíticas)
    SELECT 
        pe.*,
        ROW_NUMBER() OVER (PARTITION BY pe.id_empresa, pe.id_ordem_producao ORDER BY pe.nr_seq_etapa) AS nr_ordem_etapa,
        (pe.qt_produzida + pe.qt_perda_operador) AS vl_volume_processado_atual
    FROM producao_etapa pe
),

analise_com_lag AS (
    -- 5.1. Propagação analítica do volume liberado da etapa anterior
    SELECT 
        es.id_empresa,
        es.id_ordem_producao,
        es.nr_seq_etapa,
        es.cd_etapa,
        es.id_recurso, 
        es.qt_produzida,
        es.qt_perda_operador,
        es.qt_perda_sistema_33,
        es.qt_total_perda_registrada,
        es.vl_volume_processado_atual,
        LAG(
            CASE 
                WHEN es.nr_ordem_etapa = 1 THEN es.qt_produzida 
                ELSE es.vl_volume_processado_atual 
            END
        ) OVER (PARTITION BY es.id_empresa, es.id_ordem_producao ORDER BY es.nr_seq_etapa) AS vl_prod_liberada_ant,
        LAG(es.cd_etapa) OVER (PARTITION BY es.id_empresa, es.id_ordem_producao ORDER BY es.nr_seq_etapa) AS cd_etapa_anterior,
        NVL(fc.vl_fator_conversao, 1)    AS vl_fator_conversao,
        NVL(pp.vl_perc_perda_dinamica, 0) AS vl_perc_tolerancia_op,
        NVL(pp.vl_perda_estimada_op, 0)   AS vl_vol_perda_estimada_op,
        NVL(pp.nr_pistas_corte, 1)        AS nr_pistas_corte
    FROM etapa_sequenciada es
    LEFT JOIN fator_conversao fc 
        ON fc.id_empresa = es.id_empresa AND fc.id_ordem_producao = es.id_ordem_producao AND fc.nr_seq_etapa = es.nr_seq_etapa
    INNER JOIN perda_prevista_op pp 
        ON pp.id_empresa = es.id_empresa AND pp.id_ordem_producao = es.id_ordem_producao
),

detecao_corte_pistas AS (
    -- 5.2. Avaliação de gatilho de corte longitudinal (slitting)
    SELECT 
        a.*,
        CASE 
            WHEN a.nr_pistas_corte > 1 
             AND a.vl_volume_processado_atual >= (a.vl_prod_liberada_ant * a.nr_pistas_corte * 0.8)
            THEN 1 
            ELSE 0 
        END AS fl_atingiu_gatilho_corte
    FROM analise_com_lag a
),

propagacao_pistas AS (
    -- 5.3. Rastreamento e propagação temporal do estado de corte
    SELECT 
        d.*,
        NVL(MAX(d.fl_atingiu_gatilho_corte) OVER (
            PARTITION BY d.id_empresa, d.id_ordem_producao 
            ORDER BY d.nr_seq_etapa 
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ), 0) AS fl_pistas_ja_aplicadas_ant,
        MAX(d.fl_atingiu_gatilho_corte) OVER (
            PARTITION BY d.id_empresa, d.id_ordem_producao 
            ORDER BY d.nr_seq_etapa 
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS fl_pistas_ja_aplicadas_acum
    FROM detecao_corte_pistas d
),

calculo_desvio AS (
    -- 6. Motor Matemático: Ajuste de Meta e Normalização Linear para a Bobina-Mãe
    SELECT 
        id_empresa,
        id_ordem_producao,
        cd_etapa_anterior,
        cd_etapa AS cd_etapa_atual,
        id_recurso,
        vl_perc_tolerancia_op,
        vl_vol_perda_estimada_op,
        nr_pistas_corte,
        vl_fator_conversao,
        qt_produzida,
        qt_perda_operador,
        qt_perda_sistema_33,
        qt_total_perda_registrada,
        vl_volume_processado_atual,
        CASE 
            WHEN cd_etapa = 60 AND vl_fator_conversao > 0 THEN 
                CASE 
                    WHEN (fl_pistas_ja_aplicadas_acum = 1) AND nr_pistas_corte > 1 
                    THEN (vl_prod_liberada_ant / (vl_fator_conversao * nr_pistas_corte))
                    ELSE (vl_prod_liberada_ant / vl_fator_conversao)
                END
            WHEN fl_atingiu_gatilho_corte = 1 AND fl_pistas_ja_aplicadas_ant = 0 AND nr_pistas_corte > 1 
            THEN (vl_prod_liberada_ant * nr_pistas_corte)
            ELSE vl_prod_liberada_ant
        END AS vl_meta_ajustada,
        CASE 
            WHEN cd_etapa = 60 AND vl_fator_conversao > 0 
            THEN ROUND(qt_produzida * vl_fator_conversao, 2)
            WHEN fl_pistas_ja_aplicadas_acum = 1 AND nr_pistas_corte > 1 
            THEN ROUND(qt_produzida / nr_pistas_corte, 2)
            ELSE qt_produzida
        END AS qt_boa_equiv_bobina_mae_mt
    FROM propagacao_pistas
)

-- =====================================================================================
-- 7. MODELAGEM FINAL DE AUDITORIA & DRILL-DOWN ANALÍTICO
-- =====================================================================================
SELECT 
    cd.id_empresa,
    cd.id_ordem_producao,
    op.id_produto                                 AS cd_produto,
    cpa.ds_item                                   AS ds_produto,
    cpa.ds_grupo                                  AS ds_grupo_pa,
    cpa.ds_subgrupo                               AS ds_subgrupo_pa,
    cpa.ds_classe_produto                         AS ds_classe_pa,
    cpa.ds_familia                                AS ds_familia_pa,
    cc.cd_componente,
    cc.ds_componente,
    cc.fornecedor_componente,
    cc.ds_grupo_componente,
    cc.ds_subgrupo_comp,
    cc.ds_classe_comp,
    cc.ds_familia_comp,
    ROUND(cc.vl_consumo_total_componente, 2)      AS vl_consumo_total_componente,
    ROUND(cc.vl_proporcao_consumo * 100, 2)       AS vl_perc_proporcao_insumo,
    cd.cd_etapa_anterior,
    et_ant.ds_etapa                               AS nm_etapa_anterior,
    cd.cd_etapa_atual,
    et_atu.ds_etapa                               AS nm_etapa_atual,
    cd.id_recurso                                 AS cd_maquina,
    rec.nm_recurso                                AS nm_maquina,
    ROUND(cd.vl_meta_ajustada * NVL(cc.vl_proporcao_consumo, 1), 2)           AS vl_meta_volume_rateada,
    ROUND(cd.qt_produzida * NVL(cc.vl_proporcao_consumo, 1), 2)               AS qt_produzida_boa_rateada,
    ROUND(cd.qt_boa_equiv_bobina_mae_mt * NVL(cc.vl_proporcao_consumo, 1), 2) AS qt_boa_equiv_mae_rateada_mt,
    ROUND(cd.vl_volume_processado_atual * NVL(cc.vl_proporcao_consumo, 1), 2)     AS vl_tot_processado_rateado,
    ROUND(cd.vl_perc_tolerancia_op * 100, 2)                                   AS vl_perc_perda_prevista_eng,
    ROUND(cd.vl_vol_perda_estimada_op * NVL(cc.vl_proporcao_consumo, 1), 2)       AS vl_perda_prev_rateada_mt,
    ROUND(cd.qt_perda_sistema_33 * NVL(cc.vl_proporcao_consumo, 1), 2)        AS qt_perda_real_rateada_mt,
    ROUND(
        ( (cd.qt_perda_sistema_33 * NVL(cc.vl_proporcao_consumo, 1)) / NULLIF(cc.vl_consumo_total_componente, 0) ) * 100,
        4
    ) AS vl_perc_perda_vs_consumo_insumo,
    CASE 
        WHEN ( ((cd.qt_perda_sistema_33 * NVL(cc.vl_proporcao_consumo, 1)) / NULLIF(cc.vl_consumo_total_componente, 0)) * 100 ) 
             >= (cd.vl_perc_tolerancia_op * 100 * 2) THEN 'CRÍTICO'
        WHEN ( ((cd.qt_perda_sistema_33 * NVL(cc.vl_proporcao_consumo, 1)) / NULLIF(cc.vl_consumo_total_componente, 0)) * 100 ) 
             > (cd.vl_perc_tolerancia_op * 100) THEN 'ATENÇÃO'
        WHEN ( ((cd.qt_perda_sistema_33 * NVL(cc.vl_proporcao_consumo, 1)) / NULLIF(cc.vl_consumo_total_componente, 0)) * 100 ) 
             >= (cd.vl_perc_tolerancia_op * 100 * 0.8) THEN 'ALERTA LEVE'
        ELSE 'OK'
    END AS ds_status_farol
FROM calculo_desvio cd
INNER JOIN ops_no_periodo op 
    ON op.id_empresa = cd.id_empresa AND op.id_ordem_producao = cd.id_ordem_producao
INNER JOIN cad_classificacao_item cpa 
    ON cpa.id_empresa = op.id_empresa AND cpa.cd_item = op.id_produto
INNER JOIN consumo_componentes_op cc 
    ON cc.id_empresa = cd.id_empresa AND cc.id_ordem_producao = cd.id_ordem_producao
LEFT JOIN erp_producao.dim_etapa_operacao et_ant 
    ON et_ant.id_empresa = cd.id_empresa AND et_ant.cd_etapa = cd.cd_etapa_anterior
LEFT JOIN erp_producao.dim_etapa_operacao et_atu 
    ON et_atu.id_empresa = cd.id_empresa AND et_atu.cd_etapa = cd.cd_etapa_atual
LEFT JOIN erp_producao.dim_recurso_maquina rec 
    ON rec.id_empresa = cd.id_empresa AND rec.id_recurso = cd.id_recurso
WHERE cd.cd_etapa_anterior IS NOT NULL 
  AND cd.vl_volume_processado_atual > 0
ORDER BY 
    cd.id_empresa, 
    cd.id_ordem_producao, 
    cd.cd_etapa_atual, 
    cc.cd_componente;