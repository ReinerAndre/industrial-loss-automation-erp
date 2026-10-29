---

### 3. Documentação de Uso: user_guide.md


# Guia de Uso: Motor de Perdas Autônomo

Este documento detalha o comportamento do motor transacional automatizado focado em Ordens de Produção industriais.

## Como o script detecta a perda?
O script executa um "balanço de massa" lógico entre cada etapa registrada na O.P.:
1. **Pega o saldo de entrada:** Quanto do material bom veio da etapa anterior (ex: Extrusão).
2. **Avalia Desdobramentos (Setup):** Se a ficha técnica identificar que essa bobina será cortada em Múltiplas Pistas, ele recalcula a métrica esperada.
3. **Avalia Conversão (Etapa Final 60):** Avalia se o fator de conversão primário altera a volumetria da produção baseada na estrutura do produto.
4. **Calcula o gap (Furo):** `Gap = Saldo Esperado - (Produção Declarada + Perda Declarada)`.
5. Se o *Gap* for positivo, o motor injeta automaticamente um apontamento com **tipo_perda = 33** para responsabilizar a diferença e estancar distorções de estoque.

## Tratamentos Especiais no Código
- **Idempotência:** Antes de injetar os dados sistêmicos, executamos um `DELETE` das perdas `tipo = 33` referentes à OP específica. Logo, se o PPCP reabrir e fechar a OP várias vezes para realizar acertos finos de apontamento, o banco não gerará lixo transacional ou custos duplicados.
- **Controle de Pistas (Desdobramento):** O gatilho de pistas (`v_num_pistas > 1`) só é aplicado se a produção consolidada já tiver superado 80% do volume original compensado pelas pistas, protegendo paradas e apontamentos parciais no meio da operação.

## Resolução de Problemas (Troubleshooting)
- **Erro: "Você não pode encerrar OP na etapa X..."**
  - **Causa:** O usuário pertence ao grupo operacional sem alçada gerencial.
  - **Ação:** Um analista de Planejamento (PPCP) precisa ser notificado para realizar a tratativa ou autorizar a passagem da OP.
