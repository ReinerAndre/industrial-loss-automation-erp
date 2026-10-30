SET SERVEROUTPUT ON;
DECLARE
    -- ==========================================================================================
    -- VARIÁVEIS DE ENTRADA PARA AUDITORIA FORENSE DE PRODUÇÃO
    -- ==========================================================================================
    v_empresa_id            NUMBER := 1;        -- Código da Unidade/Filial
    v_ordem_producao_id     NUMBER := 100001;   -- ID da Ordem de Produção (OP) Encerrada
    v_etapa_alvo            NUMBER := 60;       -- Etapa auditada com conversão métrica

    -- ==========================================================================================
    -- VARIÁVEIS DE CONTROLE DE CÁLCULO E BALANÇO DE MASSA
    -- ==========================================================================================
    v_prod_liberada_ant     NUMBER := 0;
    v_unidade_ant           VARCHAR2(10) := NULL;
    v_primeira_etapa        BOOLEAN := TRUE;
    
    v_perda_a_apontar       NUMBER;
    v_perda_normalizada     NUMBER; -- Perda normalizada para a proporção master (Metros / MT)
    v_soma_atual            NUMBER;
    v_quantidade_aplicada   NUMBER;
    
    v_etapa_origem          NUMBER;
    v_recurso_origem        NUMBER;

    v_num_pistas            NUMBER := 1; 
    v_pistas_ja_aplicadas   BOOLEAN := FALSE;
    v_prod_ant_ajustada     NUMBER;

    -- Cursor Mestre: consolida apontamentos e perdas eliminando efeito cartesiano
    CURSOR c_etapas (cv_empresa_id NUMBER, cv_ordem_producao_id NUMBER) IS
        WITH cte_agrupado_producao AS (
            -- Consolida o volume total produzido e recursos por etapa
            SELECT 
                empresa_id,
                ordem_producao_id,
                etapa_id,
                SUM(quantidade)         AS qtd_produzida,
                MAX(unidade_medida)     AS unidade_medida,
                MAX(recurso_id)         AS recurso_id
            FROM erp_producao.fato_apontamento_producao
            WHERE empresa_id = cv_empresa_id
              AND ordem_producao_id = cv_ordem_producao_id
            GROUP BY empresa_id, ordem_producao_id, etapa_id
        ),
        cte_agrupado_perda AS (
            -- Separa perdas físicas apontadas por operadores de perdas automáticas sistêmicas
            SELECT 
                empresa_id,
                ordem_producao_id,
                etapa_id,
                NVL(SUM(CASE WHEN tipo_perda_id NOT IN (1, 2, 33) THEN quantidade ELSE 0 END), 0) AS qtd_perda_operador,
                NVL(SUM(CASE WHEN tipo_perda_id = 33 THEN quantidade ELSE 0 END), 0)             AS qtd_perda_sistema
            FROM erp_producao.fato_apontamento_perda
            WHERE empresa_id = cv_empresa_id
              AND ordem_producao_id = cv_ordem_producao_id
            GROUP BY empresa_id, ordem_producao_id, etapa_id
        )
        SELECT
            op_etapa.sequencia_etapa           AS etapa_seq,
            op_etapa.etapa_id                  AS etapa_id,
            NVL(prod.qtd_produzida, 0)         AS qtd_produzida,
            NVL(perda.qtd_perda_operador, 0)   AS qtd_perda_operador,
            NVL(perda.qtd_perda_sistema, 0)    AS qtd_perda_sistema,
            prod.unidade_medida                AS unidade_medida,
            ordem.produto_id                   AS produto_id,        
            ordem.versao_produto_id            AS versao_produto_id, 
            prod.recurso_id                    AS recurso_id
        FROM erp_producao.dim_ordem_etapa op_etapa
        INNER JOIN erp_engenharia.dim_etapa_roteiro cad_etapa
            ON cad_etapa.empresa_id = op_etapa.empresa_id
           AND cad_etapa.etapa_id   = op_etapa.etapa_id
           AND cad_etapa.indicador_retrabalho = 'N'
        INNER JOIN erp_producao.dim_ordem_producao ordem 
            ON ordem.empresa_id        = op_etapa.empresa_id 
           AND ordem.ordem_producao_id = op_etapa.ordem_producao_id
        LEFT JOIN cte_agrupado_producao prod
            ON prod.empresa_id        = op_etapa.empresa_id 
           AND prod.ordem_producao_id = op_etapa.ordem_producao_id 
           AND prod.etapa_id          = op_etapa.etapa_id
        LEFT JOIN cte_agrupado_perda perda
            ON perda.empresa_id        = op_etapa.empresa_id 
           AND perda.ordem_producao_id = op_etapa.ordem_producao_id 
           AND perda.etapa_id          = op_etapa.etapa_id
        WHERE op_etapa.empresa_id        = cv_empresa_id
          AND op_etapa.ordem_producao_id = cv_ordem_producao_id
        ORDER BY op_etapa.sequencia_etapa;

BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================');
    DBMS_OUTPUT.PUT_LINE('INICIANDO AUDITORIA FORENSE DE ORDEM DE PRODUCAO');
    DBMS_OUTPUT.PUT_LINE('EMPRESA: ' || v_empresa_id || ' | OP: ' || v_ordem_producao_id);
    DBMS_OUTPUT.PUT_LINE('======================================================');

    IF v_etapa_alvo = 60 THEN
        BEGIN
            -- 1. Identificação dinâmica de desdobramento de pistas (Slitting/Corte)
            SELECT NVL(MAX(TO_NUMBER(
                       erp_engenharia.fn_obter_parametro_ficha(
                           item.empresa_id, 
                           item.produto_id, 
                           item.versao_produto_id, 
                           item.ordem_producao_id, 
                           CASE cad_item.tipo_especificacao 
                               WHEN 1 THEN 222 
                               WHEN 4 THEN 224 
                               WHEN 5 THEN 264 
                               ELSE 224 
                           END
                       )
                   )), 1)
              INTO v_num_pistas
              FROM erp_producao.dim_ordem_producao item
             INNER JOIN erp_materiais.dim_item cad_item 
                ON cad_item.empresa_id = item.empresa_id 
               AND cad_item.produto_id = item.produto_id
             WHERE item.empresa_id        = v_empresa_id 
               AND item.ordem_producao_id = v_ordem_producao_id;

            DBMS_OUTPUT.PUT_LINE('-> Atributo de Pistas Mapeado na Ficha Tecnica: ' || v_num_pistas);

            -- 2. Varredura Cronológica de Rastreabilidade Física
            FOR r_etapa IN c_etapas(v_empresa_id, v_ordem_producao_id) LOOP
                DBMS_OUTPUT.PUT_LINE('------------------------------------------------------');
                DBMS_OUTPUT.PUT_LINE('>> ETAPA: ' || r_etapa.etapa_id || ' (Seq: ' || r_etapa.etapa_seq || ')');
                
                -- Busca fator nominal de consumo e conversão da matéria-prima
                SELECT NVL(MAX(quantidade_aplicada), 1) 
                  INTO v_quantidade_aplicada
                  FROM erp_engenharia.dim_estrutura_componente comp
                 INNER JOIN erp_engenharia.dim_grupo_componente grp
                    ON grp.empresa_id       = comp.empresa_id
                   AND grp.codigo_estrutura = comp.codigo_estrutura
                   AND grp.grupo_sequencia  = comp.grupo_sequencia
                   AND grp.descricao_grupo  LIKE '%MATERIA PRIMA%'
                 WHERE comp.empresa_id       = v_empresa_id
                   AND comp.codigo_estrutura = r_etapa.produto_id || '/' || r_etapa.versao_produto_id
                   AND comp.sequencia_uso    = 1;

                IF v_primeira_etapa THEN
                    v_primeira_etapa    := FALSE;
                    v_etapa_origem      := r_etapa.etapa_id;
                    v_recurso_origem    := r_etapa.recurso_id;
                    v_prod_liberada_ant := r_etapa.qtd_produzida; 
                    v_unidade_ant       := r_etapa.unidade_medida;

                    DBMS_OUTPUT.PUT_LINE('   [ORIGEM DO LOTE]');
                    DBMS_OUTPUT.PUT_LINE('   -> Causa raiz associada na Etapa: ' || v_etapa_origem);
                    DBMS_OUTPUT.PUT_LINE('   -> Saldo Inicial Liberado: ' || v_prod_liberada_ant);
                ELSE
                    -- Balanço de massa real: soma de material conforme e refugo reportado
                    v_soma_atual        := r_etapa.qtd_produzida + r_etapa.qtd_perda_operador;
                    v_prod_ant_ajustada := v_prod_liberada_ant;

                    DBMS_OUTPUT.PUT_LINE('   [GATILHOS MATEMATICOS DE ENGENHARIA]');
                    
                    -- GATILHO 1: Multiplicação por desdobro de pistas (Slitting)
                    IF NOT v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                        IF v_soma_atual >= (v_prod_liberada_ant * v_num_pistas * 0.8) THEN
                            v_prod_ant_ajustada   := v_prod_liberada_ant * v_num_pistas;
                            v_pistas_ja_aplicadas := TRUE;
                            DBMS_OUTPUT.PUT_LINE('      * DESDOBRO DE PISTAS! Multiplicando por ' || v_num_pistas || ' pistas.');
                            DBMS_OUTPUT.PUT_LINE('      * Calculo: ' || v_prod_liberada_ant || ' x ' || v_num_pistas || ' = ' || v_prod_ant_ajustada);
                        END IF;
                    END IF;

                    -- GATILHO 2: Conversão de Unidades (ex: Metros lineares para Milheiros)
                    IF r_etapa.etapa_id = 60 AND v_quantidade_aplicada > 0 THEN
                        DBMS_OUTPUT.PUT_LINE('      * CONVERSAO DE UNIDADE DETECTADA (Etapa ' || v_etapa_alvo || ').');
                        DBMS_OUTPUT.PUT_LINE('      * Fator nominal de conversao: ' || v_quantidade_aplicada);
                        
                        IF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_prod_ant_ajustada := v_prod_ant_ajustada / (v_quantidade_aplicada * v_num_pistas);
                            DBMS_OUTPUT.PUT_LINE('      * Pistas aplicadas previamente: divisor (' || v_quantidade_aplicada || ' * ' || v_num_pistas || ')');
                        ELSE
                            v_prod_ant_ajustada := v_prod_ant_ajustada / v_quantidade_aplicada;
                        END IF;
                        
                        DBMS_OUTPUT.PUT_LINE('      * Meta ajustada convertida: ' || ROUND(v_prod_ant_ajustada, 5));
                    END IF;

                    DBMS_OUTPUT.PUT_LINE('   [AUDITORIA FISICA]');
                    DBMS_OUTPUT.PUT_LINE('      (A) Esperado pela Engenharia: ' || ROUND(v_prod_ant_ajustada, 5));
                    DBMS_OUTPUT.PUT_LINE('      (B) Apontado em Operacao:    ' || ROUND(v_soma_atual, 5) || ' (Prod: '||r_etapa.qtd_produzida||' + Refugo: '||r_etapa.qtd_perda_operador||')');

                    -- Verificação de desvio material e normalização para a bobina/lote mãe
                    IF ROUND(v_soma_atual, 5) < ROUND(v_prod_ant_ajustada, 5) THEN
                        v_perda_a_apontar := v_prod_ant_ajustada - v_soma_atual;
                        
                        IF r_etapa.etapa_id = 60 AND v_quantidade_aplicada > 0 THEN
                            v_perda_normalizada := v_perda_a_apontar * v_quantidade_aplicada;
                        ELSIF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_perda_normalizada := v_perda_a_apontar / v_num_pistas;
                        ELSE
                            v_perda_normalizada := v_perda_a_apontar;
                        END IF;
                        
                        DBMS_OUTPUT.PUT_LINE('      (C) Desvio Calculado:         ' || ROUND(v_perda_a_apontar, 5) || ' (Unidade local)');
                        DBMS_OUTPUT.PUT_LINE('      (D) Perda Normalizada (Mãe):  ' || ROUND(v_perda_normalizada, 5) || ' MT (Base balanceada)');
                        DBMS_OUTPUT.PUT_LINE('      (E) Registrado Sistemicamente:' || ROUND(r_etapa.qtd_perda_sistema, 5));
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('      >>> STATUS: OK. Todo material foi balanceado. Sem desvios.');
                    END IF;

                    -- Propaga o balanço físico para a próxima etapa na cadeia
                    v_prod_liberada_ant := v_soma_atual; 
                    v_unidade_ant       := r_etapa.unidade_medida;
                END IF;
            END LOOP;

        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('ERRO DURANTE AUDITORIA: ' || SQLERRM);
        END;
    END IF;

    DBMS_OUTPUT.PUT_LINE('======================================================');
    DBMS_OUTPUT.PUT_LINE('FIM DA AUDITORIA');
    DBMS_OUTPUT.PUT_LINE('======================================================');
END;
/
