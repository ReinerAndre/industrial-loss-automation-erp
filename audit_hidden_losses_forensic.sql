SET SERVEROUTPUT ON
DECLARE
    -- ==========================================================================================
    -- VARIÁVEIS DE ENTRADA PARA AUDITORIA DE ORDEM DE PRODUÇÃO
    -- ==========================================================================================
    v_empresa             NUMBER := 1;        -- Identificador da unidade de negócio / filial
    v_ordem_producao      NUMBER := 100001;   -- Número da Ordem de Produção (OP)
    v_etapa_alvo          NUMBER := 60;       -- Etapa final para execução da auditoria

    -- ==========================================================================================
    -- VARIÁVEIS DE CONTROLE DO BALANÇO DE MASSA E RENDIMENTO
    -- ==========================================================================================
    v_prod_liberada_ant   NUMBER := 0;
    v_unidade_ant         VARCHAR2(10) := NULL;
    v_primeira_etapa      BOOLEAN := TRUE;
    
    v_perda_a_apontar     NUMBER;
    v_perda_normalizada   NUMBER; -- Perda ajustada proporcionalmente à divisão de pistas
    v_soma_atual          NUMBER;
    v_quantidade_aplicada NUMBER;
    
    v_etapa_causa         NUMBER;
    v_recurso_causa       NUMBER;

    v_num_pistas          NUMBER := 1; 
    v_pistas_ja_aplicadas BOOLEAN := FALSE;
    v_prod_ant_ajustada   NUMBER;

    -- Cursor com agregação prévia para eliminar duplicidade/produto cartesiano (Fan-out)
    CURSOR c_etapas (cv_empresa NUMBER, cv_ordem_producao NUMBER) IS
        WITH AgrupadoProducao AS (
            -- Pré-agregação dos apontamentos de produção por operação/etapa
            SELECT 
                empresa_id,
                ordem_producao_id,
                etapa_id,
                SUM(quantidade_produzida) AS qtd_produzida,
                MAX(unidade_medida)       AS unidade_medida,
                MAX(recurso_id)           AS id_recurso
            FROM manufatura_schema.fato_apontamento_producao
            WHERE empresa_id = cv_empresa
              AND ordem_producao_id = cv_ordem_producao
            GROUP BY empresa_id, ordem_producao_id, etapa_id
        ),
        AgrupadoPerda AS (
            -- Pré-agregação dos apontamentos de refugo e perdas sistêmicas
            SELECT 
                empresa_id,
                ordem_producao_id,
                etapa_id,
                -- Refugo declarado em chão de fábrica (exclui perdas administrativas/sistêmicas)
                NVL(SUM(CASE WHEN tipo_perda_id NOT IN (1, 2, 33) THEN quantidade_perda ELSE 0 END), 0) AS qtd_perda_operador,
                -- Perda sistêmica/oculta apurada automaticamente
                NVL(SUM(CASE WHEN tipo_perda_id = 33 THEN quantidade_perda ELSE 0 END), 0)             AS qtd_perda_sistema_33
            FROM manufatura_schema.fato_apontamento_perda
            WHERE empresa_id = cv_empresa
              AND ordem_producao_id = cv_ordem_producao
            GROUP BY empresa_id, ordem_producao_id, etapa_id
        )
        SELECT
            oe.sequencia_etapa              AS etapa_seq,
            oe.etapa_id                     AS etapa,
            NVL(ap.qtd_produzida, 0)        AS qtd_produzida,
            NVL(pe.qtd_perda_operador, 0)   AS qtd_perda_operador,
            NVL(pe.qtd_perda_sistema_33, 0) AS qtd_perda_sistema_33,
            ap.unidade_medida               AS unidade_medida,
            op.produto_id                   AS id_produto,        
            op.versao_produto_id            AS id_versao_produto, 
            ap.id_recurso                   AS id_recurso
        FROM manufatura_schema.dim_ordem_etapa oe
        INNER JOIN manufatura_schema.dim_etapa pe_cad
            ON pe_cad.empresa_id = oe.empresa_id
           AND pe_cad.etapa_id = oe.etapa_id
           AND pe_cad.ind_retrabalho = 'N'
        INNER JOIN manufatura_schema.fato_ordem_producao op 
            ON op.empresa_id = oe.empresa_id 
           AND op.ordem_producao_id = oe.ordem_producao_id
        LEFT JOIN AgrupadoProducao ap
            ON ap.empresa_id = oe.empresa_id 
           AND ap.ordem_producao_id = oe.ordem_producao_id 
           AND ap.etapa_id = oe.etapa_id
        LEFT JOIN AgrupadoPerda pe
            ON pe.empresa_id = oe.empresa_id 
           AND pe.ordem_producao_id = oe.ordem_producao_id 
           AND pe.etapa_id = oe.etapa_id
        WHERE oe.empresa_id = cv_empresa
          AND oe.ordem_producao_id = cv_ordem_producao
        ORDER BY oe.sequencia_etapa;

BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================');
    DBMS_OUTPUT.PUT_LINE('INICIANDO AUDITORIA DE BALANÇO DE MASSA DA OP');
    DBMS_OUTPUT.PUT_LINE('EMPRESA: ' || v_empresa || ' | ORDEM: ' || v_ordem_producao);
    DBMS_OUTPUT.PUT_LINE('======================================================');

    IF v_etapa_alvo = 60 THEN
        BEGIN
            -- 1. Identificação do multiplicador de pistas via especificações de engenharia
            SELECT NVL(MAX(TO_NUMBER(
                       engenharia_schema.fn_obter_parametro_ficha(
                           p.empresa_id, 
                           p.produto_id, 
                           p.versao_produto_id, 
                           p.ordem_producao_id, 
                           CASE e.tipo_ficha_id 
                               WHEN 1 THEN 222 
                               WHEN 4 THEN 224 
                               WHEN 5 THEN 264 
                               ELSE 224 
                           END
                       )
                   )), 1)
              INTO v_num_pistas
              FROM manufatura_schema.fato_ordem_producao p
             INNER JOIN engenharia_schema.dim_item e 
                ON e.empresa_id = p.empresa_id 
               AND e.item_id = p.produto_id
             WHERE p.empresa_id = v_empresa 
               AND p.ordem_producao_id = v_ordem_producao;

            DBMS_OUTPUT.PUT_LINE('-> Atributo de Pistas Mapeado na Engenharia: ' || v_num_pistas);

            -- 2. Conciliação cronológica do fluxo produtivo etapa a etapa
            FOR r_etapa IN c_etapas(v_empresa, v_ordem_producao) LOOP
                DBMS_OUTPUT.PUT_LINE('------------------------------------------------------');
                DBMS_OUTPUT.PUT_LINE('>> ETAPA: ' || r_etapa.etapa || ' (Seq: ' || r_etapa.etapa_seq || ')');
                
                -- Busca o fator de conversão de consumo de matéria-prima
                SELECT NVL(MAX(c.quantidade_aplicada), 1) 
                  INTO v_quantidade_aplicada
                  FROM engenharia_schema.dim_estrutura_produto c
                 INNER JOIN engenharia_schema.dim_grupo_componente gc
                    ON gc.empresa_id = c.empresa_id
                   AND gc.composicao_id = c.composicao_id
                   AND gc.sequencia_grupo = c.sequencia_grupo
                   AND gc.descricao_grupo LIKE '%MATERIA PRIMA%'
                 WHERE c.empresa_id = v_empresa
                   AND c.composicao_id = r_etapa.id_produto || '/' || r_etapa.id_versao_produto
                   AND c.sequencia_aplicacao = 1;

                IF v_primeira_etapa THEN
                    v_primeira_etapa := FALSE;
                    v_etapa_causa       := r_etapa.etapa;
                    v_recurso_causa     := r_etapa.id_recurso;
                    v_prod_liberada_ant := r_etapa.qtd_produzida; 
                    v_unidade_ant       := r_etapa.unidade_medida;

                    DBMS_OUTPUT.PUT_LINE('   [ORIGEM DO LOTE]');
                    DBMS_OUTPUT.PUT_LINE('   -> Causa raiz travada na Etapa: ' || v_etapa_causa);
                    DBMS_OUTPUT.PUT_LINE('   -> Saldo Inicial Liberado: ' || v_prod_liberada_ant);
                ELSE
                    -- Saldo físico real operado
                    v_soma_atual := r_etapa.qtd_produzida + r_etapa.qtd_perda_operador;
                    v_prod_ant_ajustada := v_prod_liberada_ant;

                    DBMS_OUTPUT.PUT_LINE('   [GATILHOS MATEMÁTICOS DE ENGENHARIA]');
                    
                    -- Multiplicador por divisão de pistas (slitting / desdobramento)
                    IF NOT v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                        IF v_soma_atual >= (v_prod_liberada_ant * v_num_pistas * 0.8) THEN
                            v_prod_ant_ajustada := v_prod_liberada_ant * v_num_pistas;
                            v_pistas_ja_aplicadas := TRUE;
                            DBMS_OUTPUT.PUT_LINE('      * DESDOBRAMENTO DETECTADO! Multiplicando por ' || v_num_pistas || ' pistas.');
                            DBMS_OUTPUT.PUT_LINE('      * Cálculo: ' || v_prod_liberada_ant || ' x ' || v_num_pistas || ' = ' || v_prod_ant_ajustada);
                        END IF;
                    END IF;

                    -- Conversão de unidade/medida na etapa final
                    IF r_etapa.etapa = 60 AND v_quantidade_aplicada > 0 THEN
                        DBMS_OUTPUT.PUT_LINE('      * CONVERSÃO DE UNIDADE DETECTADA (Etapa 60).');
                        DBMS_OUTPUT.PUT_LINE('      * Fator de conversão (Qtd. Aplicada): ' || v_quantidade_aplicada);
                        DBMS_OUTPUT.PUT_LINE('      * Cálculo: ' || v_prod_ant_ajustada || ' / ' || v_quantidade_aplicada || ' = ' || ROUND((v_prod_ant_ajustada / v_quantidade_aplicada), 2));
                        v_prod_ant_ajustada := v_prod_ant_ajustada / v_quantidade_aplicada;
                    END IF;

                    DBMS_OUTPUT.PUT_LINE('   [AUDITORIA FÍSICA]');
                    DBMS_OUTPUT.PUT_LINE('      (A) Esperado pela Engenharia: ' || ROUND(v_prod_ant_ajustada, 5));
                    DBMS_OUTPUT.PUT_LINE('      (B) Apontado em Operação:     ' || ROUND(v_soma_atual, 5) || ' (Prod: ' || r_etapa.qtd_produzida || ' + Refugo: ' || r_etapa.qtd_perda_operador || ')');

                    -- Verificação de desvio material e normalização
                    IF ROUND(v_soma_atual, 5) < ROUND(v_prod_ant_ajustada, 5) THEN
                        v_perda_a_apontar := v_prod_ant_ajustada - v_soma_atual;
                        
                        -- Normalização: divide a perda pelo número de pistas para reportar na causa raiz master
                        IF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_perda_normalizada := v_perda_a_apontar / v_num_pistas;
                        ELSE
                            v_perda_normalizada := v_perda_a_apontar;
                        END IF;
                        
                        DBMS_OUTPUT.PUT_LINE('      (C) Desvio Calculado:         ' || ROUND(v_perda_a_apontar, 5) || ' (Unidade da etapa)');
                        DBMS_OUTPUT.PUT_LINE('      (D) Perda Normalizada (Real): ' || ROUND(v_perda_normalizada, 5) || ' <-- Volume a apontar na causa raiz');
                        DBMS_OUTPUT.PUT_LINE('      (E) Perda Sistêmica Gravada:  ' || ROUND(r_etapa.qtd_perda_sistema_33, 5));
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('      >>> STATUS: OK. Todo material foi justificado. Nenhuma perda detectada.');
                    END IF;

                    -- Propagação do saldo físico real entregue pela etapa
                    v_prod_liberada_ant := v_soma_atual; 
                    v_unidade_ant       := r_etapa.unidade_medida;
                END IF;
            END LOOP;

        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('ERRO INESPERADO PL/SQL: ' || SQLERRM);
        END;
    END IF;

    DBMS_OUTPUT.PUT_LINE('======================================================');
    DBMS_OUTPUT.PUT_LINE('FIM DA AUDITORIA');
    DBMS_OUTPUT.PUT_LINE('======================================================');
END;
/
