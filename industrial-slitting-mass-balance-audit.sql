WITH joint_orders_map AS (
    -- Mapeia o agrupamento de Ordens de Produção (OPs) conjugadas na etapa de corte/refile
    -- e consolida o percentual de participação planejado para o rateio de matéria-prima
    SELECT company_id,
           master_order_id,
           child_order_id,
           SUM(allocation_share_pct) AS planned_share_pct
      FROM erp_prod.joint_production_orders
     WHERE company_id = :p_company_id
       AND operation_step_id = 10
     GROUP BY company_id, master_order_id, child_order_id
),
period_finished_orders AS (
    -- Identifica todas as OPs que tiveram apontamento de produção encerrado no período analisado
    SELECT DISTINCT pr.company_id,
           pr.order_id
      FROM erp_prod.production_entries pr
     WHERE pr.company_id = :p_company_id
       AND pr.operation_step_id = 10
       AND pr.finished_at >= TO_DATE(:p_start_date, 'DD/MM/YYYY HH24:MI:SS')
),
target_order_groups AS (
    -- Garante a integridade do grupo: se ao menos uma OP filha rodou no período,
    -- todo o conjunto da OP Principal é trazido para evitar distorções de saldo
    SELECT DISTINCT fo.company_id,
           NVL(jm.master_order_id, fo.order_id) AS master_order_id
      FROM period_finished_orders fo
      LEFT JOIN joint_orders_map jm
        ON jm.company_id     = fo.company_id
       AND jm.child_order_id = fo.order_id
),
order_universe AS (
    -- Expande a lista completa de OPs (principais e filhas) pertencentes aos grupos selecionados
    SELECT tg.company_id,
           tg.master_order_id,
           NVL(jm.child_order_id, tg.master_order_id) AS child_order_id,
           NVL(jm.planned_share_pct, 100) AS planned_share_pct
      FROM target_order_groups tg
      LEFT JOIN joint_orders_map jm
        ON jm.company_id      = tg.company_id
       AND jm.master_order_id = tg.master_order_id
),
production_by_order AS (
    -- Consolida a produção boa por OP e converte o volume físico para área padrão (m2)
    SELECT pr.company_id,
           pr.order_id,
           MAX(pr.product_code) AS product_code,
           SUM(pr.quantity) AS produced_qty,
           SUM(NVL(erp_core.fn_convert_uom(pr.company_id, pr.product_code, pr.bom_version, 'M2', pr.quantity, 'I'), 0)) AS produced_area_m2
      FROM erp_prod.production_entries pr
     WHERE pr.company_id = :p_company_id
       AND pr.operation_step_id = 10
       AND EXISTS (
           SELECT 1
             FROM order_universe ou
            WHERE ou.company_id     = pr.company_id
              AND ou.child_order_id = pr.order_id
       )
     GROUP BY pr.company_id, pr.order_id
),
consumption_by_order AS (
    -- Consolida o consumo de insumos por OP em m2 e contabiliza apontamentos manuais fora do rateio automático
    SELECT cm.company_id,
           cm.order_id,
           SUM(cm.quantity) AS consumed_qty,
           SUM(NVL(erp_core.fn_convert_uom(cm.company_id, cm.material_code, cm.material_version, 'M2', cm.quantity, 'I'), 0)) AS consumed_area_m2,
           SUM(CASE WHEN cm.auto_allocate_flag = 'N' OR cm.allocation_batch_id IS NULL THEN 1 ELSE 0 END) AS unallocated_entries_cnt
      FROM erp_prod.material_consumption_entries cm
     WHERE cm.company_id = :p_company_id
       AND cm.operation_step_id = 10
       AND EXISTS (
           SELECT 1
             FROM order_universe ou
            WHERE ou.company_id     = cm.company_id
              AND ou.child_order_id = cm.order_id
       )
     GROUP BY cm.company_id, cm.order_id
),
group_analytics AS (
    -- Aplica Window Functions para calcular o balanço físico consolidado do grupo conjugado
    -- mantendo a granularidade individual de cada OP filha
    SELECT ou.company_id,
           ou.master_order_id,
           ou.child_order_id,
           ou.planned_share_pct,
           po.product_code,
           NVL(po.produced_area_m2, 0) AS order_produced_m2,
           NVL(co.consumed_area_m2, 0) AS order_actual_consumed_m2,
           NVL(co.unallocated_entries_cnt, 0) AS unallocated_entries_cnt,
           SUM(NVL(po.produced_area_m2, 0)) OVER (PARTITION BY ou.company_id, ou.master_order_id) AS group_total_produced_m2,
           SUM(NVL(co.consumed_area_m2, 0)) OVER (PARTITION BY ou.company_id, ou.master_order_id) AS group_total_consumed_m2,
           COUNT(*) OVER (PARTITION BY ou.company_id, ou.master_order_id) AS orders_in_group_cnt
      FROM order_universe ou
      LEFT JOIN production_by_order po
        ON po.company_id = ou.company_id
       AND po.order_id   = ou.child_order_id
      LEFT JOIN consumption_by_order co
        ON co.company_id = ou.company_id
       AND co.order_id   = ou.child_order_id
)
-- Camada final de auditoria: calcula o consumo teórico perfeito, desvios de rateio e classifica anomalias
SELECT ga.company_id,
       ga.master_order_id,
       ga.child_order_id,
       ga.orders_in_group_cnt,
       ga.product_code,
       ROUND(ga.planned_share_pct, 4) AS planned_share_pct,
       ROUND((ga.order_produced_m2 / NULLIF(ga.group_total_produced_m2, 0)) * 100, 4) AS actual_production_share_pct,
       ROUND(ga.order_produced_m2, 2) AS order_produced_m2,
       ROUND(ga.order_actual_consumed_m2, 2) AS order_actual_consumed_m2,
       ROUND(ga.group_total_consumed_m2 * (ga.planned_share_pct / 100), 2) AS order_ideal_consumed_m2,
       ROUND(ga.order_actual_consumed_m2 - (ga.group_total_consumed_m2 * (ga.planned_share_pct / 100)), 2) AS allocation_variance_m2,
       ROUND(ga.group_total_produced_m2 - ga.group_total_consumed_m2, 2) AS group_mass_balance_m2,
       ROUND((ga.group_total_produced_m2 / NULLIF(ga.group_total_consumed_m2, 0)) * 100, 2) AS group_yield_pct,
       ga.unallocated_entries_cnt,
       CASE
           WHEN ga.group_total_consumed_m2 = 0 OR ga.group_total_produced_m2 = 0
               THEN 'CRITICAL: MISSING UOM CONVERSION OR ZERO ENTRY'
           WHEN ga.group_total_produced_m2 > (ga.group_total_consumed_m2 * 1.01)
               THEN 'PHYSICAL ERROR: GROUP OUTPUT > INPUT'
           WHEN ga.group_total_produced_m2 < (ga.group_total_consumed_m2 * 0.90)
               THEN 'PHYSICAL ALERT: GROUP SCRAP > 10%'
           WHEN ABS(ga.order_actual_consumed_m2 - (ga.group_total_consumed_m2 * (ga.planned_share_pct / 100))) > 5
               THEN 'ALLOCATION ERROR: DEVIATES FROM IDEAL CONSUMPTION'
           WHEN ABS(ga.planned_share_pct - ((ga.order_produced_m2 / NULLIF(ga.group_total_produced_m2, 0)) * 100)) > 1
               THEN 'PROCESS ALERT: ACTUAL SHARE VS PLANNED SHARE'
           ELSE 'OK'
       END AS audit_status
  FROM group_analytics ga
 ORDER BY ga.master_order_id, ga.child_order_id;