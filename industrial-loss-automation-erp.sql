DECLARE
    -- ==========================================================================================
    -- VARIÁVEIS DE PARÂMETRO DA ROTINA DE ENCERRAMENTO DA ORDEM DE PRODUÇÃO (OP)
    -- ==========================================================================================
    v_empresa        NUMBER := :p_1;
    v_op             NUMBER := :p_2;
    v_etapa          NUMBER := :p_3;
    v_seq_etapa      NUMBER := :p_4;
    v_recurso        NUMBER := :p_5;
    v_msg            VARCHAR2(200);
    v_usuario        NUMBER;
    v_usuario_sessao NUMBER;
    v_op_etapa       NUMBER;

    -- ==========================================================================================
    -- VARIÁVEIS DE CONTROLE DO CÁLCULO DE PERDAS PRODUTIVAS (WORKFLOW FLEXOGRÁFICO)
    -- ==========================================================================================
    v_prod_liberada_ant   NUMBER := 0;
    v_unidade_ant         VARCHAR2(10) := NULL;
    v_primeira_etapa      BOOLEAN := TRUE;
    v_perda_a_apontar     NUMBER;
    v_perda_normalizada   NUMBER; 
    v_soma_atual          NUMBER;
    v_id_usuario_numero   NUMBER := 1; -- Sistema/Admin
    v_quantidade_aplicada NUMBER;
    
    -- Causa Raiz Travada
    v_etapa_causa         NUMBER;
    v_recurso_causa       NUMBER;

    -- Controle Dinâmico de Pistas (Desdobramento/Slitting)
    v_num_pistas          NUMBER := 1; 
    v_pistas_ja_aplicadas BOOLEAN := FALSE;
    v_prod_ant_ajustada   NUMBER;

    -- Cursor Mestre: Agrupa todo o histórico de produção e perdas por etapa da OP atual
    CURSOR c_etapas (cv_empresa NUMBER, cv_op NUMBER) IS
        SELECT
            op_etapa.seq_etapa                    ETAPA_SEQ,
            op_etapa.etapa                        ETAPA,
            NVL(SUM(apont_prod.quantidade), 0)    QTD_PRODUZIDA,
            NVL(SUM(apont_perda.quantidade), 0)   QTD_PERDA,
            MAX(apont_prod.unidade)               UNIDADE_MEDIDA,
            MAX(apont_prod.produto)               ID_PRODUTO,
            MAX(apont_prod.versao)                ID_VERSAO_PRODUTO,
            MAX(apont_prod.recurso)               ID_RECURSO
        FROM erp_schema.ordem_producao_etapa op_etapa
        INNER JOIN erp_schema.etapa etapa_cad
           ON etapa_cad.empresa = op_etapa.empresa
          AND etapa_cad.codigo = op_etapa.etapa
          AND etapa_cad.retrabalho = 'N'
        LEFT JOIN erp_schema.apontamento_producao apont_prod 
           ON apont_prod.empresa = op_etapa.empresa 
          AND apont_prod.op = op_etapa.op 
          AND apont_prod.etapa = op_etapa.etapa
        LEFT JOIN erp_schema.apontamento_perda apont_perda 
           ON apont_perda.empresa = op_etapa.empresa 
          AND apont_perda.op = op_etapa.op 
          AND apont_perda.etapa = op_etapa.etapa
          AND apont_perda.tipo_perda NOT IN (1, 2) -- Ignora perdas normais já contabilizadas
        WHERE op_etapa.empresa = cv_empresa
          AND op_etapa.op = cv_op
        GROUP BY op_etapa.seq_etapa, op_etapa.etapa
        ORDER BY op_etapa.seq_etapa;

BEGIN
    -- ==========================================================================================
    -- 1. VALIDAÇÃO DE GOVERNANÇA: Apenas usuários autorizados podem encerrar OPs na etapa crítica
    -- ==========================================================================================
    SELECT etapa INTO v_op_etapa
      FROM erp_schema.ordem_producao_etapa
     WHERE empresa = v_empresa
       AND op = v_op
       AND etapa = v_etapa;

    IF v_op_etapa <> 17 THEN
        SELECT decode(is_number(action), 1, action, NULL) INTO v_usuario_sessao
          FROM v$session
         WHERE audsid = userenv('sessionid')
           AND rownum = 1;

        SELECT count(*) INTO v_usuario
          FROM erp_schema.usuario_grupo_item ugi, erp_schema.usuario usr
         WHERE ugi.id_usuario = usr.id
           AND id_grupousu = 641
           AND usr.cpf = v_usuario_sessao;

        IF v_usuario > 0 THEN
            v_msg := 'Você não pode encerrar OP na etapa ' || v_etapa || ', solicite apoio ao Planejamento (PPCP)!';
        END IF;
    END IF;

    -- ==========================================================================================
    -- 2. LÓGICA DE APONTAMENTO AUTOMÁTICO DE PERDA OCULTA (Auditoria de Eficiência)
    -- ==========================================================================================
    IF v_etapa = 60 THEN
        BEGIN
            -- LIMPEZA PRÉVIA: Garante idempotência caso a OP seja reaberta e encerrada novamente
            DELETE FROM erp_schema.apontamento_perda 
             WHERE empresa = v_empresa 
               AND op = v_op 
               AND tipo_perda = 33;
            
            -- CÁLCULO DE DESDOBRAMENTO: Identifica o número de pistas dinamicamente com base na ficha técnica
            SELECT NVL(MAX(TO_NUMBER(
                       erp_schema.f_busca_valor_ficha(
                           p.empresa, p.produto, p.versao, p.op, 
                           CASE e.tipo_ficha 
                               WHEN 1 THEN 222 
                               WHEN 4 THEN 224 
                               WHEN 5 THEN 264 
                               ELSE 224 
                           END
                       )
                   )), 1)
              INTO v_num_pistas
              FROM erp_schema.ordem_producao p
             INNER JOIN erp_schema.item_cadastro e 
                ON e.empresa = p.empresa 
               AND e.codigo = p.produto
             WHERE p.empresa = v_empresa 
               AND p.op = v_op;

            -- PROCESSAMENTO CRONOLÓGICO: Analisa perdas entre cada fase (Extrusão, Impressão, Corte)
            FOR r_etapa IN c_etapas(v_empresa, v_op) LOOP
                
                -- FATOR DE CONVERSÃO: Busca taxa de conversão da matéria-prima principal para o produto
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
                ELSE
                    v_soma_atual := r_etapa.QTD_PRODUZIDA + r_etapa.QTD_PERDA;
                    v_prod_ant_ajustada := v_prod_liberada_ant;

                    -- GATILHO DE PISTAS: Multiplica produção esperada baseada nas bobinas divididas no setup
                    IF NOT v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                        IF v_soma_atual >= (v_prod_liberada_ant * v_num_pistas * 0.8) THEN
                            v_prod_ant_ajustada := v_prod_liberada_ant * v_num_pistas;
                            v_pistas_ja_aplicadas := TRUE;
                        END IF;
                    END IF;

                    -- GATILHO DE CONVERSÃO FINAL: Ajusta volume para a unidade de medida do produto final
                    IF r_etapa.etapa = 60 AND v_quantidade_aplicada > 0 THEN
                        v_prod_ant_ajustada := v_prod_ant_ajustada / v_quantidade_aplicada;
                    END IF;

                    -- AUDITORIA: Registra perda sistêmica oculta (Gargalos não apontados manualmente)
                    IF v_soma_atual < v_prod_ant_ajustada THEN
                        v_perda_a_apontar := v_prod_ant_ajustada - v_soma_atual;

                        IF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_perda_normalizada := v_perda_a_apontar / v_num_pistas;
                        ELSE
                            v_perda_normalizada := v_perda_a_apontar;
                        END IF;

                        INSERT INTO erp_schema.apontamento_perda (
                            EMPRESA, SEQUENCIAL, OP, RECURSO, QUANTIDADE, PRODUTO,
                            ETAPA_CAUSA, RECURSO_CAUSA, TIPO_PERDA, DATA_HORA, USUARIO,
                            ETAPA, VERSAO, UNIDADE, SEQ_ETAPA, ORIGEM_AP
                        ) VALUES (
                            v_empresa, erp_schema.SEQ_APONTAMENTO_PERDA.NEXTVAL, v_op, r_etapa.ID_RECURSO,
                            ROUND(v_perda_normalizada, 5), r_etapa.ID_PRODUTO, v_etapa_causa, v_recurso_causa, 
                            33, SYSDATE, v_id_usuario_numero, r_etapa.ETAPA, r_etapa.ID_VERSAO_PRODUTO, 
                            r_etapa.UNIDADE_MEDIDA, r_etapa.ETAPA_SEQ, NULL
                        );
                        commit; 
                    END IF;

                    -- ATUALIZAÇÃO DO SALDO: Repassa apenas a produção física real aprovada
                    v_prod_liberada_ant := v_soma_atual; 
                    v_unidade_ant       := r_etapa.UNIDADE_MEDIDA;
                END IF;
            END LOOP;

        EXCEPTION
            WHEN OTHERS THEN
                ROLLBACK; 
                v_msg := 'ERRO ao calcular perda sistêmica automática: ' || SQLERRM;
        END;
    END IF;

    -- ==========================================================================================
    -- 3. RETORNO DE SUCESSO/FALHA PARA A CAMADA DE APLICAÇÃO
    -- ==========================================================================================
    :p_8 := v_msg;

END;