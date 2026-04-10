-- ============================================================
--  VIEW 4: vw_loss_analysis
--
--  One row per batch per stage (stages with yield only).
--  Answers: How many units were lost at each stage?
--  Which stage, dosage form, or generic drives the most loss?
--  Used for: Page 4 (Lead Time & Loss dashboard)
-- ============================================================
 
CREATE OR REPLACE VIEW vw_loss_analysis AS
 
WITH stage_yields AS (
    -- Pivot yield values per batch into one row per jo_id.
    -- We need all stage yields in the same row to compute the
    -- stage input-output chain for material loss.
    SELECT
        fbp.jo_id,
        djo.batch_size,
        MAX(CASE WHEN fbp.stage = 'dry_blending'
            THEN fbp.yield_pct END)   AS yield_dry_blending,
        MAX(CASE WHEN fbp.stage = 'compression'
            THEN fbp.yield_pct END)   AS yield_compression,
        MAX(CASE WHEN fbp.stage = 'encapsulation'
            THEN fbp.yield_pct END)   AS yield_encapsulation,
        MAX(CASE WHEN fbp.stage = 'coating'
            THEN fbp.yield_pct END)   AS yield_coating
    FROM fact_batch_production fbp
    JOIN dim_job_order djo ON fbp.jo_id = djo.jo_id
    GROUP BY fbp.jo_id, djo.batch_size
),
 
loss_per_stage AS (
    -- Compute loss units at each stage using the input-output chain.
    --
    -- Stage chain logic (units flow forward through production):
    --   dry_blending  input  = batch_size (raw material)
    --   compression   input  = dry_blending output
    --   encapsulation input  = dry_blending output (capsules skip compression)
    --   coating       input  = compression output
    --
    -- Loss formula: input_units × (1 − yield_pct)
    --   If yield = 0.97 (97%), then 3% of input is lost.
    --   loss_units = input × (1 − 0.97) = input × 0.03
    --
    -- NULLIF prevents division/multiplication errors when yield is NULL.
    SELECT
        jo_id,
        batch_size,
        yield_dry_blending,
        yield_compression,
        yield_encapsulation,
        yield_coating,
 
        -- Computed outputs (units that pass each stage)
        ROUND(batch_size * COALESCE(yield_dry_blending, 1), 0)
            AS dry_blending_output,
 
        ROUND(batch_size * COALESCE(yield_dry_blending, 1)
                         * COALESCE(yield_compression, 1), 0)
            AS compression_output,
 
        -- Loss at each stage
        CASE WHEN yield_dry_blending IS NOT NULL
            THEN ROUND(batch_size * (1 - yield_dry_blending), 0)
            ELSE NULL
        END AS loss_dry_blending,
 
        CASE WHEN yield_compression IS NOT NULL
            THEN ROUND(
                batch_size * COALESCE(yield_dry_blending, 1)
                           * (1 - yield_compression),
                0)
            ELSE NULL
        END AS loss_compression,
 
        CASE WHEN yield_encapsulation IS NOT NULL
            THEN ROUND(
                batch_size * COALESCE(yield_dry_blending, 1)
                           * (1 - yield_encapsulation),
                0)
            ELSE NULL
        END AS loss_encapsulation,
 
        CASE WHEN yield_coating IS NOT NULL
            THEN ROUND(
                batch_size * COALESCE(yield_dry_blending, 1)
                           * COALESCE(yield_compression, 1)
                           * (1 - yield_coating),
                0)
            ELSE NULL
        END AS loss_coating
 
    FROM stage_yields
)
 
-- Final SELECT: unpivot loss columns back to tall format.
-- Power BI works best with a long table (stage, loss_units) rather than wide.
-- We use UNION ALL to stack each stage as its own row.
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    dd.full_date                          AS production_date,
    EXTRACT(YEAR FROM dd.full_date)::INT  AS year,
    EXTRACT(MONTH FROM dd.full_date)::INT AS month,
    TO_CHAR(dd.full_date, 'Month')        AS month_name,
    EXTRACT(QUARTER FROM dd.full_date)::INT AS quarter,
    'dry_blending'                        AS stage,
    ROUND(lps.yield_dry_blending * 100, 2) AS yield_pct,
    lps.loss_dry_blending                 AS loss_units
 
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'dry_blending'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_dry_blending IS NOT NULL
 
UNION ALL
 
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    dd.full_date,
    EXTRACT(YEAR FROM dd.full_date)::INT,
    EXTRACT(MONTH FROM dd.full_date)::INT,
    TO_CHAR(dd.full_date, 'Month'),
    EXTRACT(QUARTER FROM dd.full_date)::INT,
    'compression',
    ROUND(lps.yield_compression * 100, 2),
    lps.loss_compression
 
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'compression'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_compression IS NOT NULL
 
UNION ALL
 
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    dd.full_date,
    EXTRACT(YEAR FROM dd.full_date)::INT,
    EXTRACT(MONTH FROM dd.full_date)::INT,
    TO_CHAR(dd.full_date, 'Month'),
    EXTRACT(QUARTER FROM dd.full_date)::INT,
    'encapsulation',
    ROUND(lps.yield_encapsulation * 100, 2),
    lps.loss_encapsulation
 
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'encapsulation'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_encapsulation IS NOT NULL
 
UNION ALL
 
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    dd.full_date,
    EXTRACT(YEAR FROM dd.full_date)::INT,
    EXTRACT(MONTH FROM dd.full_date)::INT,
    TO_CHAR(dd.full_date, 'Month'),
    EXTRACT(QUARTER FROM dd.full_date)::INT,
    'coating',
    ROUND(lps.yield_coating * 100, 2),
    lps.loss_coating
 
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'coating'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_coating IS NOT NULL
 
ORDER BY jo_number, stage;
 