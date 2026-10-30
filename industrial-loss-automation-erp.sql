DECLARE
    -- ==========================================================================================
    -- VARIÁVEIS DE PARÂMETROS DO EVENTO (Trigger / Hook do ERP)
    -- ==========================================================================================
    v_empresa_id         NUMBER := :p_empresa_id;
    v_ordem_producao_id  NUMBER := :p_ordem_producao_id;
    v_etapa_id           NUMBER := :p_etapa_id;
    v_sequencia_etapa    NUMBER := :p_sequencia_etapa;
    v_recurso_id         NUMBER := :p_recurso_id;
    v_mensagem_retorno   VARCHAR2(200);
    v_total_permissoes   NUMBER;
    v_documento_sessao   NUMBER;
    v_etapa_atual_op     NUMBER;

    -- ==========================================================================================
    -- VARIÁVEIS DE CONTROLE DO CÁLCULO E BALANÇO DE MASSA
    -- ==========================================================================================
    v_prod_liberada_ant   NUMBER := 0;
    v_unidade_ant         VARCHAR2(10) := NULL;
    v_primeira_etapa      BOOLEAN := TRUE;
    v_perda_a_apontar     NUMBER;
    v_perda_normalizada   NUMBER; 
    v_soma_atual          NUMBER;
    v_usuario_sistema_id  NUMBER := 1; -- Usuário de serviço/automação para inserções sistêmicas
    v_quantidade_aplicada NUMBER;
    
    -- Rastreabilidade de Causa Raiz
    v_etapa_origem        NUMBER;
    v_recurso_origem      NUMBER;

    -- Controle Dinâmico de Pistas (Desdobramento / Slitting)
    v_num_pistas          NUMBER := 1; 
    v_pistas_ja_aplicadas BOOLEAN := FALSE;
    v_prod_ant_ajustada   NUMBER;

    -- Cursor Mestre: Agrupamento isolado para eliminar produto cartesiano
    CURSOR c_etapas (cv_empresa_id NUMBER, cv_ordem_producao_id NUMBER) IS
        WITH cte_agrupado_producao AS (
            -- Consolidação da produção física por etapa
            SELECT 
                empresa_id,
                ordem_producao_id,
                etapa_id,
                SUM(quantidade)     AS qtd_produzida,
                MAX(unidade_medida) AS unidade_medida,
                MAX(recurso_id)     AS recurso_id
            FROM erp_producao.fato_apontamento_producao
            WHERE empresa_id        = cv_empresa_id
              AND ordem_producao_id = cv_ordem_producao_id
            GROUP BY empresa_id, ordem_producao_id, etapa_id
        ),
        cte_agrupado_perda AS (
            -- Isolamento de refugos apontados manualmente pela operação
            SELECT 
                empresa_id,
                ordem_producao_id,
                etapa_id,
                NVL(SUM(CASE WHEN tipo_perda_id NOT IN (1, 2, 33) THEN quantidade ELSE 0 END), 0) AS qtd_perda_operador
            FROM erp_producao.fato_apontamento_perda
            WHERE empresa_id        = cv_empresa_id
              AND ordem_producao_id = cv_ordem_producao_id
            GROUP BY empresa_id, ordem_producao_id, etapa_id
        )
        SELECT
            op_etapa.sequencia_etapa           AS etapa_seq,
            op_etapa.etapa_id                  AS etapa_id,
            NVL(prod.qtd_produzida, 0)         AS qtd_produzida,
            NVL(perda.qtd_perda_operador, 0)   AS qtd_perda,
            prod.unidade_medida                AS unidade_medida,
            ordem.produto_id                   AS produto_id,
            ordem.versao_produto_id            AS versao_produto_id,
            prod.recurso_id                    AS recurso_id
        FROM erp_producao.dim_ordem_etapa op_etapa
        INNER JOIN erp_engenharia.dim_etapa_roteiro cad_etapa
            ON cad_etapa.empresa_id            = op_etapa.empresa_id
           AND cad_etapa.etapa_id              = op_etapa.etapa_id
           AND cad_etapa.indicador_retrabalho  = 'N'
        INNER JOIN erp_producao.dim_ordem_producao ordem 
            ON ordem.empresa_id                = op_etapa.empresa_id 
           AND ordem.ordem_producao_id         = op_etapa.ordem_producao_id
        LEFT JOIN cte_agrupado_producao prod
            ON prod.empresa_id                 = op_etapa.empresa_id 
           AND prod.ordem_producao_id          = op_etapa.ordem_producao_id 
           AND prod.etapa_id                   = op_etapa.etapa_id
        LEFT JOIN cte_agrupado_perda perda
            ON perda.empresa_id                = op_etapa.empresa_id 
           AND perda.ordem_producao_id         = op_etapa.ordem_producao_id 
           AND perda.etapa_id                  = op_etapa.etapa_id
        WHERE op_etapa.empresa_id              = cv_empresa_id
          AND op_etapa.ordem_producao_id       = cv_ordem_producao_id
        ORDER BY op_etapa.sequencia_etapa;

BEGIN
    -- ==========================================================================================
    -- 1. VALIDAÇÃO DE SEGURANÇA E GOVERNANÇA DE ENCERRAMENTO
    -- ==========================================================================================
    SELECT etapa_id INTO v_etapa_atual_op
      FROM erp_producao.dim_ordem_etapa
     WHERE empresa_id        = v_empresa_id
       AND ordem_producao_id = v_ordem_producao_id
       AND etapa_id          = v_etapa_id;

    IF v_etapa_atual_op <> 17 THEN
        SELECT DECODE(REGEXP_LIKE(action, '^[0-9]+$'), TRUE, TO_NUMBER(action), NULL) 
          INTO v_documento_sessao
          FROM v$session
         WHERE audsid = USERENV('sessionid')
           AND ROWNUM = 1;

        SELECT COUNT(*) INTO v_total_permissoes
          FROM erp_seguranca.dim_grupo_usuario_item rel_grupo
         INNER JOIN erp_seguranca.dim_usuario cad_usuario
            ON cad_usuario.usuario_id = rel_grupo.usuario_id
         WHERE rel_grupo.grupo_id     = 641
           AND cad_usuario.documento_identificacao = v_documento_sessao;

        IF v_total_permissoes > 0 THEN
            v_mensagem_retorno := 'Encerramento não autorizado na etapa ' || v_etapa_id || '. Contate o planejamento e controle de produção!';
        END IF;
    END IF;

    -- ==========================================================================================
    -- 2. LÓGICA DE APONTAMENTO AUTOMÁTICO DE PERDA OCULTA (Executa no Encerramento da OP)
    -- ==========================================================================================
    IF v_etapa_id = 60 THEN
        BEGIN
            -- IDEMPOTÊNCIA: Limpeza prévia para permitir reabertura sem duplicar registros
            DELETE FROM erp_producao.fato_apontamento_perda 
             WHERE empresa_id        = v_empresa_id 
               AND ordem_producao_id = v_ordem_producao_id 
               AND tipo_perda_id     = 33;
            
            -- Identificação dinâmica do número de pistas técnicas cadastradas
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

            -- Processamento em cadeia das etapas produtivas da OP
            FOR r_etapa IN c_etapas(v_empresa_id, v_ordem_producao_id) LOOP
                
                -- Busca o fator nominal de consumo da matéria-prima estrutural
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
                    
                    -- Registra a etapa e o maquinário de origem para cálculo de rastreabilidade
                    v_etapa_origem      := r_etapa.etapa_id;
                    v_recurso_origem    := r_etapa.recurso_id;
                    
                    v_prod_liberada_ant := r_etapa.qtd_produzida; 
                    v_unidade_ant       := r_etapa.unidade_medida;
                ELSE
                    -- Saldo físico real operado (volume conforme + descarte de processo reportado)
                    v_soma_atual        := r_etapa.qtd_produzida + r_etapa.qtd_perda;
                    v_prod_ant_ajustada := v_prod_liberada_ant;

                    -- GATILHO DE PISTAS (Corte / Slitting longitudinal)
                    IF NOT v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                        IF v_soma_atual >= (v_prod_liberada_ant * v_num_pistas * 0.8) THEN
                            v_prod_ant_ajustada   := v_prod_liberada_ant * v_num_pistas;
                            v_pistas_ja_aplicadas := TRUE;
                        END IF;
                    END IF;

                    -- GATILHO DE CONVERSÃO UNITÁRIA (Etapa 60)
                    IF r_etapa.etapa_id = 60 AND v_quantidade_aplicada > 0 THEN
                        IF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_prod_ant_ajustada := v_prod_ant_ajustada / (v_quantidade_aplicada * v_num_pistas);
                        ELSE
                            v_prod_ant_ajustada := v_prod_ant_ajustada / v_quantidade_aplicada;
                        END IF;
                    END IF;

                    -- AUDITORIA: Registra desvio de processo sistemicamente se houver quebra de balanço
                    IF v_soma_atual < v_prod_ant_ajustada THEN
                        v_perda_a_apontar := v_prod_ant_ajustada - v_soma_atual;

                        -- NORMALIZAÇÃO: Reconversão para escala métrica master do lote original
                        IF r_etapa.etapa_id = 60 AND v_quantidade_aplicada > 0 THEN
                            v_perda_normalizada := v_perda_a_apontar * v_quantidade_aplicada;
                        ELSIF v_pistas_ja_aplicadas AND v_num_pistas > 1 THEN
                            v_perda_normalizada := v_perda_a_apontar / v_num_pistas;
                        ELSE
                            v_perda_normalizada := v_perda_a_apontar;
                        END IF;

                        INSERT INTO erp_producao.fato_apontamento_perda (
                            empresa_id, sequencial_id, ordem_producao_id, recurso_id, quantidade, produto_id,
                            etapa_origem_id, recurso_origem_id, tipo_perda_id, data_apontamento, usuario_id,
                            etapa_id, versao_produto_id, unidade_medida, sequencia_etapa, origem_apontamento
                        ) VALUES (
                            v_empresa_id,
                            erp_producao.seq_fato_apontamento_perda.NEXTVAL,
                            v_ordem_producao_id,
                            r_etapa.recurso_id,
                            ROUND(v_perda_normalizada, 5),
                            r_etapa.produto_id,
                            v_etapa_origem,
                            v_recurso_origem,
                            33,
                            SYSDATE,
                            v_usuario_sistema_id,
                            r_etapa.etapa_id,
                            r_etapa.versao_produto_id,
                            r_etapa.unidade_medida,
                            r_etapa.etapa_seq,
                            NULL
                        );
                        
                        COMMIT; 
                    END IF;

                    -- Propaga o saldo físico real operado para a próxima etapa da cadeia
                    v_prod_liberada_ant := v_soma_atual; 
                    v_unidade_ant       := r_etapa.unidade_medida;
                    
                END IF;
            END LOOP;

        EXCEPTION
            WHEN OTHERS THEN
                ROLLBACK; 
                v_mensagem_retorno := 'ERRO ao calcular perda automática 33: ' || SQLERRM;
        END;
    END IF;

    -- ==========================================================================================
    -- 3. RETORNO DE STATUS DO EVENTO
    -- ==========================================================================================
    :p_mensagem_retorno := v_mensagem_retorno;

END;
/
