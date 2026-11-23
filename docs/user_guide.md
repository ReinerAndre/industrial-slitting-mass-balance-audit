```markdown
# Guia de Uso Operacional — Auditoria de Balanço de Massa ($m^2$) e Rateio de Refile

## 1. Visão Geral do Processo
No processo de corte/refile, uma bobina-mãe de matéria-prima é dividida em bobinas menores. Por princípio físico de conservação de área, o total de $m^2$ consumidos deve ser equivalente ao total de $m^2$ bons produzidos, descontada apenas a apara técnica natural da máquina.

Como diversas Ordens de Produção (OPs) são processadas em conjunto (**OPs Conjugadas**), este relatório audita o apontamento em **dois níveis simultâneos**:
1. **Nível do Grupo (`master_order_id`):** Verifica se a soma física de tudo o que entrou e tudo o que saiu no corte fecha dentro da tolerância esperada.
2. **Nível da OP Individual (`child_order_id`):** Verifica se o consumo total do grupo foi rateado corretamente para cada OP conforme o peso planejado (`planned_share_pct`).

---

## 2. Dicionário de Colunas do Relatório

| Coluna | Descrição Técnica e Operacional |
| :--- | :--- |
| `company_id` | Código da unidade fabril / empresa analisada. |
| `master_order_id` | Número da OP Principal que comanda o corte e agrupa as OPs conjugadas. |
| `child_order_id` | Número de cada OP individual participante do corte (inclui a principal e as filhas). |
| `orders_in_group_cnt` | Quantidade de OPs rodando juntas no mesmo corte (`1` = OP avulsa; `>= 2` = conjugada). |
| `product_code` | Código do item acabado produzido na OP. |
| `planned_share_pct` | Percentual (%) de participação cadastrado no planejamento para ratear o consumo. |
| `actual_production_share_pct` | Percentual (%) real que a OP representou sobre o total de $m^2$ produzidos pelo grupo. |
| `order_produced_m2` | Área total ($m^2$) de produção boa apontada na OP individual. |
| `order_actual_consumed_m2` | Área total ($m^2$) de matéria-prima efetivamente baixada na OP individual. |
| `order_ideal_consumed_m2` | **Consumo Perfeito ($m^2$):** Consumo total do grupo multiplicado pelo `planned_share_pct`. |
| `allocation_variance_m2` | Desvio de rateio (`order_actual_consumed_m2 - order_ideal_consumed_m2`). Positivo = baixado a mais; Negativo = baixado a menos. |
| `group_mass_balance_m2` | Saldo físico consolidado do corte (`group_total_produced_m2 - group_total_consumed_m2`). |
| `group_yield_pct` | Rendimento físico global do grupo em % (ex.: `97,00%` indica `3,00%` de apara/refugo). |
| `unallocated_entries_cnt` | Quantidade de apontamentos de consumo lançados manualmente sem passar pelo rateio automático. |
| `audit_status` | Diagnóstico automático da linha para priorização de tratativa. |

---

## 3. Matriz de Diagnóstico e Ação (`audit_status`)

| Status | Causa Provável | Procedimento de Correção |
| :--- | :--- | :--- |
| **`OK`** | Balanço físico do grupo dentro do padrão e rateio fiel ao planejamento. | Nenhuma ação necessária. OP apta para fechamento. |
| **`PHYSICAL ERROR: GROUP OUTPUT > INPUT`** | Produção total em $m^2$ maior que o consumo do grupo (fisicamente impossível). | Conferir se faltou apontar bobina consumida na `master_order_id` ou se houve apontamento duplicado de produção. |
| **`PHYSICAL ALERT: GROUP SCRAP > 10%`** | Rendimento do conjunto abaixo de `90%`. | Verificar dupla baixa de lote/bobina no consumo, falha de apontamento de produção em alguma OP filha ou refugo anormal. |
| **`ALLOCATION ERROR: DEVIATES FROM IDEAL CONSUMPTION`** | O saldo total do grupo fechou, mas a divisão entre as OPs divergiu do `order_ideal_consumed_m2`. | Verificar se `unallocated_entries_cnt > 0`. Estornar a baixa manual avulsa e refazer o apontamento pelo rateio da OP Principal. |
| **`PROCESS ALERT: ACTUAL SHARE VS PLANNED SHARE`** | A proporção real produzida entre as pistas divergiu do percentual cadastrado na conjugação. | Revisar os percentuais de participação (`planned_share_pct`) na conjugação para refletir o rendimento real de cada pista. |
| **`CRITICAL: MISSING UOM CONVERSION OR ZERO ENTRY`** | Item sem fator de conversão para $m^2$ cadastrado ou OP sem apontamento completo. | Se a OP já estiver encerrada, acionar Engenharia/Cadastro para configurar o fator de conversão para `M2`. |
