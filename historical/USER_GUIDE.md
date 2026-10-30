# 📖 User Guide: Implementação e Consumo do Modelo de Perdas

Este guia detalha como parametrizar, validar e conectar o script SQL ao ambiente produtivo e às camadas de visualização (BI).

---

## 1. Parâmetros de Execução

O script foi concebido para execução direta no banco Oracle ou via gerador de relatórios do ERP.

### Parâmetros Obrigatórios (CTE `ops_no_periodo`)
| Parâmetro | Tipo | Exemplo | Descrição |
| :--- | :--- | :--- | :--- |
| `id_empresa` | `NUMBER` | `1` | Código da unidade fabril |
| `cd_tipo_perda`| `NUMBER` | `33` | Código da perda automática de balanço de massa |
| `dt_registro` (Início) | `DATE` | `TO_DATE('2026-10-01', 'YYYY-MM-DD')` | Início do intervalo de auditoria |
| `dt_registro` (Fim) | `DATE` | `TO_DATE('2026-11-01', 'YYYY-MM-DD')` | Fim do intervalo de auditoria |

> **Nota Técnica:** O filtro de data atua **apenas na seleção das OPs**. Todo o consumo de matéria-prima e os apontamentos de máquina anteriores ou posteriores a essa data são calculados integralmente para manter a coerência do balanço da ordem.

---

## 2. Dicionário de Colunas da Camada de Saída

| Coluna | Tipo | Descrição |
| :--- | :--- | :--- |
| `id_ordem_producao` | Numérico | Número da Ordem de Produção |
| `cd_produto` / `ds_produto` | Texto | Código e descrição do Produto Acabado (PA) |
| `cd_componente` / `ds_componente` | Texto | Código e descrição do Insumo (Filme/Substrato) |
| `fornecedor_componente` | Texto | Marca/Fabricante do insumo cadastrado na base |
| `vl_proporcao_consumo` | Percentual | Participação do insumo no volume total consumido pela OP |
| `nm_etapa_anterior` / `nm_etapa_atual` | Texto | Roteiro operacional da transição (De -> Para) |
| `nm_maquina` | Texto | Recurso produtivo onde ocorreu o processamento |
| `qt_produzida_boa_rateada` | Decimal (MT) | Metragem física aprovada na etapa, rateada para o insumo |
| `qt_boa_equiv_mae_rateada_mt`| Decimal (MT) | **Métrica Normalizada:** Volume equivalente de bobina-mãe |
| `vl_perda_prev_rateada_mt` | Decimal (MT) | Volume de refugo planejado pela Engenharia de Produto |
| `qt_perda_real_rateada_mt` | Decimal (MT) | Refugo real de processo apurado (Tipo 33) |
| `vl_perc_perda_vs_consumo_insumo` | Percentual | % de Refugo Real apurado sobre o total aplicado do insumo |
| `ds_status_farol` | Categórico | Indicador de risco: `OK`, `ALERTA LEVE`, `ATENÇÃO`, `CRÍTICO` |

---

## 3. Conexão com Ferramentas de BI (Power BI / Metabase)

### Modo Recomendado: Importação via View
Recomenda-se encapsular o script numa `VIEW` no schema analítico:
```sql
CREATE OR REPLACE VIEW dw_manufatura.vw_auditoria_perdas_etapa AS
-- [Inserir o código SQL - historical_data_analysis.sql]
```
### Configuração de Visuais no BI

1. Visual de Matriz (Fluxo da Esteira Produtiva):
   
    * Linhas: id_ordem_producao, ds_produto, ds_componente, fornecedor_componente.
    * Colunas: cd_etapa_atual ou nm_etapa_atual.
    * Valores: qt_boa_equiv_mae_rateada_mt (Soma) e qt_perda_real_rateada_mt (Soma).
      
2. Formatação Condicional (Farol):
   
  * Aplicar regra de cor de fundo no campo ds_status_farol:
      * CRÍTICO Vermelho Escuro (#D9534F)
      * ATENÇÃO Âmbar (#F0AD4E)
      * ALERTA LEVE Amarelo Claro (#FCF8E3)
      * OK Verde Claro (#5CB85C)
        
## 4. Troubleshooting & FAQ

* **P: Por que a produção na etapa de Selagem é muito maior que na Impressão?**  
  *R:* A etapa opera com múltiplas pistas (*slitting* já efetuado). Para comparar com a matéria-prima de entrada, utilize sempre a coluna `qt_boa_equiv_mae_rateada_mt`.

* **P: A soma das perdas rateadas bate exatamente com o total apontado na OP?**  
  *R:* Sim. A soma das proporções de carga de todos os componentes da OP resulta sempre em 1,000000 (100%), o que assegura matematicamente que não há criação nem desaparecimento de metros lineares de refugo.
