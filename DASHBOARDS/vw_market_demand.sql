-- ============================================================
--  VIEW 5: vw_market_demand
--
--  One row per batch (with date and volume context).
--  Answers: What are the production trends over time?
--  Which generics are growing? Where is concentration risk?
--  Used for: Page 5 (Market Demand dashboard)
-- ============================================================
 
CREATE OR REPLACE VIEW vw_market_demand AS
 
WITH batch_base AS (
    -- One row per job order, anchored to the compounding date.
    -- Compounding is always the first stage, so it's the most reliable
    -- date to use as the "production start" timestamp for trend analysis.
    -- We join to fact_batch_production filtered to dry_blending stage
    -- because dry_blending is where compounding yield and date are recorded.
    SELECT
        djo.jo_id,
        djo.jo_number,
        dp.product_name,
        dp.generic_name,
        dp.dosage_form,
        djo.batch_size,
        dd.full_date     AS production_date,
        dd.year,
        dd.month,
        dd.month_name,
        dd.quarter
    FROM dim_job_order djo
    JOIN dim_product dp ON djo.product_id = dp.product_id
    JOIN fact_batch_production fbp
        ON djo.jo_id = fbp.jo_id
       AND fbp.stage = 'dry_blending'
    LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
    WHERE dd.full_date IS NOT NULL
),
 
-- Compute total annual batch count per generic for concentration share
annual_totals AS (
    SELECT
        year,
        COUNT(*) AS total_batches_year
    FROM batch_base
    GROUP BY year
)
 
SELECT
    bb.jo_id,
    bb.jo_number,
    bb.product_name,
    bb.generic_name,
    bb.dosage_form,
    bb.batch_size,
    bb.production_date,
    bb.year,
    bb.month,
    bb.month_name,
    bb.quarter,
 
    -- Half-year flag for H1 vs H2 comparison
    CASE
        WHEN bb.month <= 6 THEN 'H1'
        ELSE 'H2'
    END                                              AS half_year,
 
    -- Annual totals for share calculation in Power BI
    at.total_batches_year,
 
    -- Each batch = 1 production event.
    -- Power BI will SUM batch_count to aggregate across filters.
    1                                                AS batch_count
 
FROM batch_base bb
JOIN annual_totals at ON bb.year = at.year
ORDER BY bb.production_date, bb.generic_name;
 