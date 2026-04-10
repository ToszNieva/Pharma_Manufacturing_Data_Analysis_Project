-- ============================================================
--  VIEW 2: vw_yield_vs_target
--
--  One row per batch (jo_id) per stage.
--  Answers: What is the yield for each batch at each stage?
--  Is this batch above or below target? What is the gap?
--  Used for: Page 3 (Yield Performance dashboard)
-- ============================================================
 
CREATE OR REPLACE VIEW vw_yield_vs_target AS
 
WITH latest_targets AS (
    -- Same target versioning logic as View 1.
    -- Here we keep stage + dosage_form granularity because yield targets
    -- differ by dosage form (e.g. coating is 96% for Film-Coated but
    -- not applicable for plain Tablet). We need the match at batch level.
    SELECT
        stage,
        dosage_form,
        target_yield_pct
    FROM dim_stage_target dst1
    WHERE effective_date = (
        SELECT MAX(effective_date)
        FROM dim_stage_target dst2
        WHERE dst2.stage    = dst1.stage
          AND dst2.dosage_form = dst1.dosage_form
    )
)
 
SELECT
    -- Identifiers
    fbp.fact_id,
    fbp.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    fbp.stage,
 
    -- Machine context
    dm.machine_name,
    dm.machine_type,
 
    -- Date context
    dd.full_date                                AS production_date,
    dd.year,
    dd.month,
    dd.month_name,
    dd.quarter,
 
    -- Batch size
    djo.batch_size,
 
    -- Yield measures
    ROUND(fbp.yield_pct * 100, 2)              AS yield_pct,
    lt.target_yield_pct,
    ROUND((fbp.yield_pct * 100) - lt.target_yield_pct, 2) AS yield_gap,
 
    -- Compliance flag (batch-level — critical for Power BI drill-down)
    CASE
        WHEN fbp.yield_pct IS NULL                              THEN 'NO DATA'
        WHEN fbp.yield_pct * 100 >= lt.target_yield_pct        THEN 'MET TARGET'
        ELSE 'BELOW TARGET'
    END                                          AS compliance_status,
 
    -- Binary flag for easy DAX measure: % of batches below target
    CASE
        WHEN fbp.yield_pct IS NOT NULL
         AND fbp.yield_pct * 100 < lt.target_yield_pct         THEN 1
        ELSE 0
    END                                          AS is_below_target
 
FROM fact_batch_production fbp
JOIN dim_job_order  djo ON fbp.jo_id       = djo.jo_id
JOIN dim_product    dp  ON fbp.product_id  = dp.product_id
LEFT JOIN dim_machine dm ON fbp.machine_id = dm.machine_id
LEFT JOIN dim_date   dd  ON fbp.date_id    = dd.date_id
LEFT JOIN latest_targets lt
       ON fbp.stage::TEXT     = lt.stage::TEXT
      AND dp.dosage_form::TEXT = lt.dosage_form::TEXT
 
-- Exclude compounding sub-stages from yield reporting:
-- wet_granulation has no separate yield column (it feeds into dry_blending).
-- dry_blending holds the compounding yield (% Yield_Cmpdg).
-- In Power BI we will label dry_blending as "Compounding" for business clarity.
WHERE fbp.stage NOT IN ('wet_granulation')
  AND fbp.yield_pct IS NOT NULL
 
ORDER BY djo.jo_number, fbp.stage;