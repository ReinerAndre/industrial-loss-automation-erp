# Otimização do Balanço de Massa e Apontamento de Perdas (ERP/Manufatura)

## 📌 O Desafio de Negócio

Na indústria de manufatura contínua (com forte foco no fluxo flexográfico), ocorrem divergências constantes entre a matéria-prima inserida e a quantidade de produto acabado reportado. Anteriormente, as perdas de material entre etapas produtivas (Extrusão, Impressão, Corte) dependiam do apontamento manual dos operadores. Isso gerava inconsistências nos balanços de massa, ofuscava os gargalos no chão de fábrica e deturpava o custo real (CMV) das Ordens de Produção (OPs).

## 🎯 O Objetivo

- Automatizar o apontamento de perdas "ocultas" (parasitas) que não eram reportadas manualmente.
- Ajustar os cálculos dinamicamente considerando processos complexos (ex: desdobramento de bobinas/pistas).
- Validar as conversões de unidade de medida entre a matéria-prima e o produto final de forma sistêmica.
- Garantir rastreabilidade para o sistema de BI visualizar exatamente em qual etapa a eficiência operacional caiu.

📐 Arquitetura do Fluxo de Dados

``` mermaid
flowchart LR
    subgraph Origem
        A1[Fichas Técnicas] --> A[Coleta de Apontamentos]
        A2[Chão de Fábrica] --> A
    end

    subgraph Processamento Lógico (Database Engine)
        B1[Check de Governança de Usuários] --> B2
        B2[Loop Cronológico por Etapas] --> B3
        B3[Cálculo de Fatores e Desdobramento] --> B4
        B4{Produção Reportada < Saldo Esperado?} 
    end

    subgraph Camada de Entrega
        C1[(ERP - Tabela de Perdas)]
        B4 -- Sim --> C1
    end

    A --> B1
    C1 --> D(BI / Dashboards de Custeio)
```

## 🛠️ A Solução Técnica

* Desenvolvemos uma procedure autônoma acionada via trigger/evento transacional no banco de dados, no momento do encerramento das OPs.

* Modularidade de Cursor: Um cursor central (c_etapas) utiliza LEFT JOINS para unificar toda a rastreabilidade da OP cronologicamente.

* Adaptação Dinâmica: O script possui lógicas específicas de negócio, lendo atributos flexíveis (tipo_ficha) para entender de forma autônoma se o item exige cálculos de desdobramento de pistas (ex: divisão de rolos longos em bobinas menores).

* Tratamento Idempotente: A rotina de perdas automatizadas faz uma limpeza prévia para prevenir duplicação de dados e garantir precisão na tabela final (tipo_perda = 33).

## 🚀 Impacto Esperado (ou Real)

* Fechamento de Custos Preciso: Visibilidade real do desperdício de insumos, permitindo à diretoria atuar na etapa específica (ex: erro no refile do corte ou acerto de impressão longo).

* Auditoria 100% Sistêmica: Redução drástica dos furos de estoque criados por omissão humana de apontamentos de refugo no chão de fábrica.

* Governança Fortalecida: Trava lógica bloqueando usuários não autorizados do grupo operacional de burlarem ou encerrarem fluxos críticos da produção sem validação do PPCP.
