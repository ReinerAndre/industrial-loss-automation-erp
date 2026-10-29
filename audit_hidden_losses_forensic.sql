SET SERVEROUTPUT ON
DECLARE
    -- ==========================================================================================
    -- VARIÁVEIS DE ENTRADA PARA AUDITORIA FORENSE DE ORDEM DE PRODUÇÃO
    -- ==========================================================================================
    v_empresa            NUMBER := 6;      
    v_op                 NUMBER := 328176; -- <== ID DA OP ENCERRADA PARA AUDITORIA
    v_etapa              NUMBER := 60;     

    -- ==========================================================================================
    -- VARIÁVEIS DE CONTROLE E BALANCEAMENTO DE MASSA
    -- ==========================================================================================
    v_prod_liberada_ant   NUMBER := 0;
    v_unidade_ant         VARCHAR2(10) := NULL;
    v_primeira_etapa      BOOLEAN := TRUE;
    
    v_perda_a_apontar     NUMBER;
    v_perda_normalizada   NUMBER; -- <== Perda normalizada para o fator master de pistas
    v_soma_atual          NUMBER;
    v_quantidade_aplicada NUMBER;
    
    v_etapa_causa         NUMBER;
    v_recurso_causa       NUMBER;

    v_num_pistas          NUMBER := 1; 
    v_pistas_ja_aplicadas BOOLEAN := FALSE;
    v_prod_ant_ajustada   NUMBER;

    -- Cursor Mestre de Auditoria: Consolida produção vs perdas manuais vs perdas automáticas gravadas (Tipo 33)
    CURSOR c_etapas (cv_empresa NUMBER, cv_op NUMBER) IS
        SELECT
            op_etapa.seq_etapa                    ETAPA_SEQ,
            op_etapa.etapa                        ETAPA,
            NVL(SUM(apont_prod.quantidade), 0)    QTD_PRODUZIDA,
            -- Perda informada manualmente pelo operador (desconsidera perdas sistêmicas e ajustes)
            NVL(SUM(CASE WHEN apont_perda.tipo_perda NOT IN (1, 2, 33) THEN apont_perda.quantidade ELSE 0 END), 0) QTD_PERDA_OPERADOR,
            -- Perda sistêmica (Tipo 33) já gravada no banco pelo motor de automação
            NVL(SUM(CASE WHEN apont_perda.tipo_perda = 33 THEN apont_perda.quantidade ELSE 0 END), 0) QTD_PERDA_SISTEMA_33,
            MAX(apont_prod.unidade)               UNIDADE_MEDIDA,
            MAX(op.produto)                       ID_PRODUTO,         
            MAX(op.versao)                        ID_VERSAO_PRODUTO,  
            MAX(apont_prod.recurso)               ID_RECURSO
        FROM erp_schema.ordem_producao_etapa op_etapa
        INNER JOIN erp_schema.etapa etapa_cad
           ON etapa_cad.empresa = op_etapa.empresa
          AND etapa_cad.codigo = op_etapa.etapa
          AND etapa_cad.retrabalho = 'N'
        INNER JOIN erp_schema.ordem_producao op 
           ON op.empresa = op_etapa.empresa 
          AND op.op = op_etapa.op
        LEFT JOIN erp_schema.apontamento_producao apont_prod 
           ON apont_prod.empresa = op_etapa.empresa 
          AND apont_prod.op = op_etapa.op 
          AND apont_prod.etapa = op_etapa.etapa
        LEFT JOIN erp_schema.apontamento_perda apont_perda 
           ON apont_perda.empresa = op_etapa.empresa 
          AND apont_perda.op = op_etapa.op 
          AND apont_perda.etapa = op_etapa.etapa
          AND apont_perda.tipo_perda = 33
        WHERE op_etapa.empresa = cv_empresa
          AND op_etapa.op = cv_op
        GROUP BY op_etapa.seq_etapa, op_etapa.etapa
        ORDER BY op_etapa.seq_etapa;

BEGIN
    DBMS_OUTPUT.PUT_LINE('======================================================');
    DBMS_OUTPUT.PUT_LINE('INICIANDO AUDITORIA FORENSE DE OP ENCERRADA');
    DBMS_OUTPUT.PUT_LINE('EMPRESA: ' || v_empresa || ' | OP: ' || v_op);
    DBMS_OUTPUT.PUT_LINE('======================================================');

    IF v_etapa = 60 THEN
        BEGIN
            -- 1. Captura dinâmica de pistas via ficha técnica do produto
            SELECT NVL(MAX(TO_NUMBER(
                       erp_schema.f_busca_valor_ficha(p.empresa, p.produto, p.versao, p.op, 
                           CASE e.tipo_ficha WHEN 1 THEN 222 WHEN 4 THEN 224 WHEN 5 THEN 264 ELSE 224 END
                       )
                   )), 1)
              INTO v_num_pistas
              FROM erp_schema.ordem_producao p
             INNER JOIN erp_schema.item_cadastro e ON e.empresa = p.empresa AND e.codigo = p.produto
             WHERE p.empresa = v_empresa AND p.op = v_op;

            DBMS_OUTPUT.PUT_LINE('-> Atributo de Pistas Mapeado na Ficha Técnica: ' || v_num_pistas);

            -- 2. Loop de Varredura Cronológica das Fases Produtivas
            FOR r_etapa IN c_etapas(v_empresa, v_op) LOOP
                DBMS_OUTPUT.PUT_LINE('------------------------------------------------------');
                DBMS_OUTPUT.PUT_LINE('>> ETAPA: ' || r_etapa.ETAPA || ' (Seq: ' || r_etapa.ETAPA_SEQ || ')');
                
                -- Busca fator de conversão de matéria-prima
                SELECT NVL(MAX(quantidade_aplicada), 1) INTO v_quantidade_aplicada
                  FROM erp_schema.componente_estrutura comp
                 INNER JOIN erp_schema.grupo_componente grupo
                    ON grupo.empresa = comp.empresa
                   AND grupo.composicao = comp.composicao
                   AND grupo.seq_grupo = comp.seq_grupo
                   AND grupo.nome_grupo LIKE '%MATERIA PRIMA%'
                 WHERE comp.empresa = v_empresa
                   AND comp.composicao = r_etapa.ID_PRODUTO || '/' || r_etapa.ID_VERSAO_PRODUTO
                   AND comp.seq_aplicacao = 1;

                IF v_primeira_etapa THEN
                    v_primeira_etapa := FALSE;
                    v_etapa_causa       := r_etapa.ETAPA;
                    v_recurso_causa     := r_etapa.ID_RECURSO;
                    v_prod_liberada_ant := r_etapa.QTD_PRODUZIDA; 
                    v_unidade_ant       := r_etapa.UNIDADE_MEDIDA;

                    DBMS_OUTPUT.PUT_LINE('   [ORIGEM DO LOTE]');
                    DBMS_OUTPUT.PUT_LINE('   -> Causa raiz travada na Etapa: ' || v_etapa_causa);
                    DBMS_OUTPUT.PUT_LINE('   -> Saldo Inicial Liberado: ' || v_prod_liberada_ant);
                ELSE
                    v_soma_atual := r_etapa.QTD_PRODUZIDA + r_etapa.QTD_PERDA_OPERADOR;
                    v_prod_ant_ajustada := v_prod_liberada_ant;

                    DBMS_OUTPUT.PUT_LINE('   [GATILHOS MATEMÁTICOS DE ENGENHARIA]');
                    
                    -- Avalia desdobramento em pistas
                    IF NOT v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                        IF v_soma_atual >= (v_prod_liberada_ant * v_num_pistas * 0.8) THEN
                            v_prod_ant_ajustada := v_prod_liberada_ant * v_num_pistas;
                            v_pistas_ja_aplicadas := TRUE;
                            DBMS_OUTPUT.PUT_LINE('      * CORTE DETECTADO! Multiplicando por ' || v_num_pistas || ' pistas.');
                            DBMS_OUTPUT.PUT_LINE('      * Cálculo: ' || v_prod_liberada_ant || ' x ' || v_num_pistas || ' = ' || v_prod_ant_ajustada);
                        END IF;
                    END IF;

                    -- Avalia conversão de unidade na etapa final
                    IF r_etapa.etapa = 60 AND v_quantidade_aplicada > 0 THEN
                        DBMS_OUTPUT.PUT_LINE('      * CONVERSÃO DETECTADA! Transformando unidades (Etapa 60).');
                        DBMS_OUTPUT.PUT_LINE('      * Fator de conversão: ' || v_quantidade_aplicada);
                        v_prod_ant_ajustada := v_prod_ant_ajustada / v_quantidade_aplicada;
                    END IF;

                    DBMS_OUTPUT.PUT_LINE('   [AUDITORIA FÍSICA COMPARATIVA]');
                    DBMS_OUTPUT.PUT_LINE('      (A) Esperado pela Engenharia: ' || ROUND(v_prod_ant_ajustada, 5));
                    DBMS_OUTPUT.PUT_LINE('      (B) Apontado pelo Operador:   ' || ROUND(v_soma_atual, 5));

                    -- Compara desvio e calcula normalizações
                    IF ROUND(v_soma_atual, 5) < ROUND(v_prod_ant_ajustada, 5) THEN
                        v_perda_a_apontar := v_prod_ant_ajustada - v_soma_atual;
                        
                        IF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_perda_normalizada := v_perda_a_apontar / v_num_pistas;
                        ELSE
                            v_perda_normalizada := v_perda_a_apontar;
                        END IF;
                        
                        DBMS_OUTPUT.PUT_LINE('      (C) Perda Calculada (Bruta):  ' || ROUND(v_perda_a_apontar, 5));
                        DBMS_OUTPUT.PUT_LINE('      (D) Perda Normalizada (Real): ' || ROUND(v_perda_normalizada, 5));
                        DBMS_OUTPUT.PUT_LINE('      (E) Gravado no Sistema (33):  ' || ROUND(r_etapa.QTD_PERDA_SISTEMA_33, 5));
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('      >>> STATUS: OK. Todo o material foi justificado.');
                    END IF;

                    v_prod_liberada_ant := v_soma_atual; 
                    v_unidade_ant       := r_etapa.UNIDADE_MEDIDA;
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