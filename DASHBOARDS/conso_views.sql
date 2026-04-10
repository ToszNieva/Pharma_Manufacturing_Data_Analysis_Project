-- ============================================================
--  POWER BI VIEWS v3 — LLI Manufacturing Analytics
--  Database : lli_db (PostgreSQL)
--  Author   : Joshua Nieva | Senior Process Lead → Data Analyst
--  Version  : 3.0 — Clean Architecture Edition
--
--  Design principles in this version:
--    1. Views expose date_key only — no year/month/quarter columns
--       inside the views. All date attributes come from vw_dim_date
--       via the relationship in Power BI model view.
--    2. dim_date is the single source of truth for all time attributes.
--    3. Views are as lean as possible — only columns that cannot
--       come from a dimension table are included.
--    4. All views dropped before creation to avoid the
--       "cannot change column name" PostgreSQL restriction.
--
--  Execution order (run top to bottom):
--    0. vw_dim_date
--    1. vw_machine_utilization
--    2. vw_yield_vs_target
--    3. vw_lead_time
--    4. vw_loss_analysis
--    5. vw_production_volume
--
--  Power BI model relationships (set in Model view):
--    vw_dim_date[date_key] → vw_machine_utilization[date_key]
--    vw_dim_date[date_key] → vw_yield_vs_target[date_key]
--    vw_dim_date[date_key] → vw_lead_time[date_key]
--    vw_dim_date[date_key] → vw_loss_analysis[date_key]
--    vw_dim_date[date_key] → vw_production_volume[date_key]
-- ============================================================


-- ============================================================
--  DROP ALL VIEWS FIRST
--  Prevents "cannot change column name" errors on re-run.
--  IF EXISTS means no error if the view doesn't exist yet.
--  Order matters: drop dependent views before base views.
-- ============================================================

DROP VIEW IF EXISTS vw_production_volume;
DROP VIEW IF EXISTS vw_loss_analysis;
DROP VIEW IF EXISTS vw_lead_time;
DROP VIEW IF EXISTS vw_yield_vs_target;
DROP VIEW IF EXISTS vw_machine_utilization;
DROP VIEW IF EXISTS vw_dim_date;


-- ============================================================
--  VIEW 0: vw_dim_date
--
--  Purpose:
--    Exposes dim_date as a Power BI-ready date dimension.
--    This is the single table Power BI marks as the Date Table,
--    enabling all DAX time intelligence functions (DATESMTD,
--    DATESYTD, DATEADD, DATESINPERIOD).
--
--  Why a view instead of connecting directly to dim_date?
--    Consistency. All objects Power BI imports are views —
--    this makes the semantic layer uniform and means you can
--    add computed columns here later (e.g. fiscal year,
--    holiday flags) without touching the base table.
--
--  Power BI setup:
--    After importing, right-click this table → Mark as date table
--    → select full_date as the date column.
--    This is required for DAX time intelligence to work.
-- ============================================================

CREATE VIEW vw_dim_date AS

SELECT
    date_id         AS date_key,
    full_date,
    year,
    quarter,
    month,
    month_name,
    week_number,
    day_of_week,
    day_name,
    is_weekend
FROM dim_date
ORDER BY date_id;


-- ============================================================
--  VIEW 1: vw_machine_utilization
--
--  Grain: one row per machine × stage × month
--
--  Why monthly grain instead of daily?
--    Machine utilization is a throughput metric — how many
--    batches did a machine process and at what yield? This is
--    only meaningful at the monthly level. Daily grain would
--    produce mostly sparse single-batch rows that add no
--    analytical value and slow Power BI down.
--
--  date_key: first day of the month (YYYYMMDD).
--    Since this view is monthly, we construct date_key as the
--    1st of each month (e.g. March 2025 → 20250301). This
--    ensures a clean join to vw_dim_date[date_key] and lets
--    DAX time intelligence treat it as a real date.
--
--  Columns intentionally excluded:
--    year, month, quarter, month_name — all come from
--    vw_dim_date via the model relationship.
-- ============================================================

CREATE VIEW vw_machine_utilization AS

WITH stage_targets AS (
    -- Get the most recent target yield for each stage.
    -- AVG across dosage forms gives one target line per stage,
    -- which is the right granularity for machine-level reporting.
    SELECT
        stage,
        AVG(target_yield_pct) AS avg_target_pct
    FROM dim_stage_target dst1
    WHERE effective_date = (
        SELECT MAX(effective_date)
        FROM dim_stage_target dst2
        WHERE dst2.stage = dst1.stage
    )
    GROUP BY stage
),

machine_monthly AS (
    SELECT
        dm.machine_id,
        dm.machine_name,
        dm.machine_type,
        fbp.stage,

        -- Construct date_key as the 1st of the month.
        -- dd.year * 10000 = YYYY0000
        -- dd.month * 100  = 00MM00
        -- + 1             = 000001
        -- Result: YYYYMM01 as an integer.
        CAST(dd.year * 10000 + dd.month * 100 + 1 AS INT) AS date_key,

        COUNT(*)                                           AS batch_count,
        ROUND(AVG(fbp.yield_pct * 100), 2)                AS avg_yield_pct,
        ROUND(MIN(fbp.yield_pct * 100), 2)                AS min_yield_pct,
        ROUND(MAX(fbp.yield_pct * 100), 2)                AS max_yield_pct,
        ROUND(STDDEV(fbp.yield_pct * 100), 2)             AS stddev_yield_pct,
        COUNT(*) FILTER (WHERE fbp.yield_pct IS NOT NULL) AS yield_recorded_count

    FROM fact_batch_production fbp
    JOIN dim_machine dm ON fbp.machine_id = dm.machine_id
    JOIN dim_date   dd  ON fbp.date_id    = dd.date_id
    WHERE fbp.machine_id IS NOT NULL
      AND fbp.yield_pct  IS NOT NULL
    GROUP BY
        dm.machine_id,
        dm.machine_name,
        dm.machine_type,
        fbp.stage,
        dd.year,
        dd.month
)

SELECT
    mm.machine_id,
    mm.machine_name,
    mm.machine_type,
    mm.stage,
    mm.date_key,
    mm.batch_count,
    mm.avg_yield_pct,
    mm.min_yield_pct,
    mm.max_yield_pct,
    mm.stddev_yield_pct,
    mm.yield_recorded_count,
    ROUND(st.avg_target_pct, 2)                     AS target_yield_pct,
    ROUND(mm.avg_yield_pct - st.avg_target_pct, 2)  AS yield_gap,
    CASE
        WHEN mm.avg_yield_pct >= st.avg_target_pct  THEN 'AT OR ABOVE TARGET'
        ELSE 'BELOW TARGET'
    END                                              AS target_status

FROM machine_monthly mm
LEFT JOIN stage_targets st ON mm.stage::TEXT = st.stage::TEXT
ORDER BY mm.date_key, mm.stage, mm.batch_count DESC;


-- ============================================================
--  VIEW 2: vw_yield_vs_target
--
--  Grain: one row per batch (jo_id) per stage
--
--  This is the most granular analytical view — every batch,
--  every stage, with its actual yield vs the applicable target.
--  It powers: Page 3 (Yield Performance) and the
--  "underperforming generics" chart on Executive Overview.
--
--  date_key: actual production date of each stage (YYYYMMDD).
--    We use the real date here (not 1st of month) because
--    batch-level yield analysis benefits from daily granularity
--    — you can drill from year → month → individual batch.
--
--  wet_granulation excluded:
--    That stage records the granulator machine used but has
--    no separate yield measurement. Including it would generate
--    a flood of NULL yield rows that distort averages.
--
--  yield_pct_raw added:
--    The decimal form (0.9750) stored alongside the display
--    form (97.50) so DAX can use AVERAGEX on the raw values
--    for weighted aggregations without needing to divide by 100.
-- ============================================================

CREATE VIEW vw_yield_vs_target AS

WITH latest_targets AS (
    -- Stage + dosage_form granularity here (unlike vw_machine_utilization)
    -- because yield targets differ by dosage form at the batch level.
    -- e.g. coating is 96% for Film-Coated but N/A for plain Tablet.
    SELECT
        stage,
        dosage_form,
        target_yield_pct
    FROM dim_stage_target dst1
    WHERE effective_date = (
        SELECT MAX(effective_date)
        FROM dim_stage_target dst2
        WHERE dst2.stage       = dst1.stage
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

    -- Date key only — all date attributes via vw_dim_date join
    dd.date_id                                              AS date_key,

    -- Batch context
    djo.batch_size,

    -- Yield measures
    ROUND(fbp.yield_pct * 100, 2)                          AS yield_pct,
    fbp.yield_pct                                          AS yield_pct_raw,
    lt.target_yield_pct,
    ROUND((fbp.yield_pct * 100) - lt.target_yield_pct, 2) AS yield_gap,

    -- Compliance status label for visuals
    CASE
        WHEN fbp.yield_pct IS NULL                        THEN 'NO DATA'
        WHEN fbp.yield_pct * 100 >= lt.target_yield_pct  THEN 'MET TARGET'
        ELSE 'BELOW TARGET'
    END                                                    AS compliance_status,

    -- Binary flag: 1 = below target, 0 = at or above.
    -- Used in DAX: DIVIDE(SUM(is_below_target), COUNT(fact_id))
    -- = below-target batch rate without complex DAX logic.
    CASE
        WHEN fbp.yield_pct IS NOT NULL
         AND fbp.yield_pct * 100 < lt.target_yield_pct    THEN 1
        ELSE 0
    END                                                    AS is_below_target

FROM fact_batch_production fbp
JOIN  dim_job_order  djo ON fbp.jo_id      = djo.jo_id
JOIN  dim_product    dp  ON fbp.product_id = dp.product_id
LEFT JOIN dim_machine dm  ON fbp.machine_id = dm.machine_id
LEFT JOIN dim_date   dd   ON fbp.date_id    = dd.date_id
LEFT JOIN latest_targets lt
       ON fbp.stage::TEXT      = lt.stage::TEXT
      AND dp.dosage_form::TEXT = lt.dosage_form::TEXT

WHERE fbp.stage    != 'wet_granulation'
  AND fbp.yield_pct IS NOT NULL

ORDER BY djo.jo_number, fbp.stage;


-- ============================================================
--  VIEW 3: vw_lead_time
--
--  Grain: one row per batch (job order)
--
--  Lead time = calendar days from compounding start to the
--  final applicable production stage, based on dosage form:
--    Capsule                    → encapsulation date
--    Film-Coated, SR, ER,
--    Enteric, Modified Release  → coating date
--    Tablet, Bilayer Tablet     → compression date
--
--  date_key: YYYYMMDD integer of the compounding date.
--    Compounding is the first stage of every batch, making it
--    the natural "batch start" anchor for time intelligence.
--    MoM lead time = did batches started this month finish
--    faster than batches started last month?
--
--  is_sla_breach binary flag:
--    Same pattern as is_below_target in vw_yield_vs_target.
--    Enables DAX SLA breach rate = DIVIDE(SUM, COUNT).
-- ============================================================

CREATE VIEW vw_lead_time AS

WITH stage_dates AS (
    -- Pivot from tall (one row per stage) to wide (one row per batch,
    -- one column per stage date) using MAX(CASE WHEN) conditional
    -- aggregation. MAX() is safe here because UNIQUE(jo_id, stage)
    -- guarantees at most one row per stage per batch.
    SELECT
        fbp.jo_id,
        MAX(CASE WHEN fbp.stage = 'wet_granulation'
            THEN dd.full_date END) AS compounding_date,
        MAX(CASE WHEN fbp.stage = 'compression'
            THEN dd.full_date END) AS compression_date,
        MAX(CASE WHEN fbp.stage = 'encapsulation'
            THEN dd.full_date END) AS encapsulation_date,
        MAX(CASE WHEN fbp.stage = 'coating'
            THEN dd.full_date END) AS coating_date
    FROM fact_batch_production fbp
    LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
    GROUP BY fbp.jo_id
),

lead_time_calc AS (
    SELECT
        djo.jo_id,
        djo.jo_number,
        dp.product_name,
        dp.generic_name,
        dp.dosage_form,
        djo.batch_size,
        sd.compounding_date,
        sd.compression_date,
        sd.encapsulation_date,
        sd.coating_date,

        -- Final stage date: dosage-form-specific routing
        CASE
            WHEN dp.dosage_form::TEXT = 'CAPSULE'
                THEN sd.encapsulation_date
            WHEN dp.dosage_form::TEXT IN (
                'FILM-COATED TABLET',
                'SUSTAINED-RELEASE TABLET',
                'EXTENDED RELEASE TABLET',
                'ENTERIC-COATED TABLET',
                'MODIFIED RELEASE TABLET'
            )   THEN sd.coating_date
            ELSE sd.compression_date
        END AS final_stage_date,

        -- Lead time in days.
        -- PostgreSQL DATE subtraction returns an INTEGER directly.
        -- No DATEDIFF() needed — that's SQL Server syntax.
        CASE
            WHEN dp.dosage_form::TEXT = 'CAPSULE'
                THEN (sd.encapsulation_date - sd.compounding_date)
            WHEN dp.dosage_form::TEXT IN (
                'FILM-COATED TABLET',
                'SUSTAINED-RELEASE TABLET',
                'EXTENDED RELEASE TABLET',
                'ENTERIC-COATED TABLET',
                'MODIFIED RELEASE TABLET'
            )   THEN (sd.coating_date - sd.compounding_date)
            ELSE (sd.compression_date - sd.compounding_date)
        END AS lead_time_days

    FROM dim_job_order djo
    JOIN dim_product dp ON djo.product_id = dp.product_id
    JOIN stage_dates sd  ON djo.jo_id     = sd.jo_id
)

SELECT
    ltc.jo_id,
    ltc.jo_number,
    ltc.product_name,
    ltc.generic_name,
    ltc.dosage_form,
    ltc.batch_size,
    ltc.compounding_date,
    ltc.compression_date,
    ltc.encapsulation_date,
    ltc.coating_date,
    ltc.final_stage_date,
    ltc.lead_time_days,

    -- date_key: YYYYMMDD integer of compounding date.
    -- CAST(TO_CHAR(..., 'YYYYMMDD') AS INT) is the safest way
    -- to convert a DATE to the YYYYMMDD integer format that
    -- dim_date uses as its primary key.
    CAST(TO_CHAR(ltc.compounding_date, 'YYYYMMDD') AS INT) AS date_key,

    -- SLA compliance (21-day internal benchmark)
    CASE
        WHEN ltc.lead_time_days IS NULL   THEN 'INCOMPLETE DATA'
        WHEN ltc.lead_time_days <= 21     THEN 'WITHIN SLA'
        ELSE 'SLA BREACH'
    END                                                    AS sla_status,

    -- Binary flag for DAX SLA breach rate measure
    CASE
        WHEN ltc.lead_time_days IS NOT NULL
         AND ltc.lead_time_days > 21                       THEN 1
        ELSE 0
    END                                                    AS is_sla_breach

FROM lead_time_calc ltc
WHERE ltc.compounding_date IS NOT NULL
ORDER BY ltc.jo_number;


-- ============================================================
--  VIEW 4: vw_loss_analysis
--
--  Grain: one row per batch per applicable stage (tall format)
--
--  Material loss chain:
--    dry_blending  input = batch_size (raw material)
--    compression   input = dry_blending output
--    encapsulation input = dry_blending output (skips compression)
--    coating       input = compression output
--
--  Loss formula per stage:
--    loss_units = stage_input × (1 − yield_pct)
--
--  COALESCE(upstream_yield, 1) assumption:
--    When an upstream yield is NULL (not recorded), we assume
--    yield = 1.0 (no upstream loss) rather than propagating NULL
--    through the chain. This is conservative — it prevents the
--    downstream stage loss from disappearing entirely just because
--    the upstream stage has a data gap.
--
--  UNION ALL structure:
--    Each stage is a separate SELECT block stacked vertically.
--    Power BI works best with tall data — stage on the legend
--    axis, loss_units on the value axis, done.
--
--  date_key: actual stage date (YYYYMMDD) for each stage block.
--    Each stage has its own date, so each UNION ALL block joins
--    back to fact_batch_production filtered to that specific stage
--    to retrieve its date_id.
-- ============================================================

CREATE VIEW vw_loss_analysis AS

WITH stage_yields AS (
    -- Pivot yields wide: one row per batch, one column per stage yield.
    -- Required so we can reference upstream yields when computing
    -- downstream stage inputs in loss_per_stage below.
    SELECT
        fbp.jo_id,
        djo.batch_size,
        MAX(CASE WHEN fbp.stage = 'dry_blending'
            THEN fbp.yield_pct END)  AS yield_dry_blending,
        MAX(CASE WHEN fbp.stage = 'compression'
            THEN fbp.yield_pct END)  AS yield_compression,
        MAX(CASE WHEN fbp.stage = 'encapsulation'
            THEN fbp.yield_pct END)  AS yield_encapsulation,
        MAX(CASE WHEN fbp.stage = 'coating'
            THEN fbp.yield_pct END)  AS yield_coating
    FROM fact_batch_production fbp
    JOIN dim_job_order djo ON fbp.jo_id = djo.jo_id
    GROUP BY fbp.jo_id, djo.batch_size
),

loss_per_stage AS (
    SELECT
        jo_id,
        batch_size,
        yield_dry_blending,
        yield_compression,
        yield_encapsulation,
        yield_coating,

        -- Stage loss calculations
        CASE WHEN yield_dry_blending IS NOT NULL
            THEN ROUND(batch_size * (1 - yield_dry_blending), 0)
        END AS loss_dry_blending,

        CASE WHEN yield_compression IS NOT NULL
            THEN ROUND(
                batch_size
                * COALESCE(yield_dry_blending, 1)
                * (1 - yield_compression), 0)
        END AS loss_compression,

        CASE WHEN yield_encapsulation IS NOT NULL
            THEN ROUND(
                batch_size
                * COALESCE(yield_dry_blending, 1)
                * (1 - yield_encapsulation), 0)
        END AS loss_encapsulation,

        CASE WHEN yield_coating IS NOT NULL
            THEN ROUND(
                batch_size
                * COALESCE(yield_dry_blending, 1)
                * COALESCE(yield_compression, 1)
                * (1 - yield_coating), 0)
        END AS loss_coating

    FROM stage_yields
)

-- dry_blending
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    'dry_blending'                          AS stage,
    ROUND(lps.yield_dry_blending * 100, 2) AS yield_pct,
    lps.loss_dry_blending                  AS loss_units,
    dd.date_id                             AS date_key
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'dry_blending'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_dry_blending IS NOT NULL

UNION ALL

-- compression
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    'compression',
    ROUND(lps.yield_compression * 100, 2),
    lps.loss_compression,
    dd.date_id
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'compression'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_compression IS NOT NULL

UNION ALL

-- encapsulation
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    'encapsulation',
    ROUND(lps.yield_encapsulation * 100, 2),
    lps.loss_encapsulation,
    dd.date_id
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'encapsulation'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_encapsulation IS NOT NULL

UNION ALL

-- coating
SELECT
    lps.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,
    lps.batch_size,
    'coating',
    ROUND(lps.yield_coating * 100, 2),
    lps.loss_coating,
    dd.date_id
FROM loss_per_stage lps
JOIN dim_job_order djo ON lps.jo_id      = djo.jo_id
JOIN dim_product   dp  ON djo.product_id = dp.product_id
LEFT JOIN fact_batch_production fbp
       ON lps.jo_id = fbp.jo_id AND fbp.stage = 'coating'
LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
WHERE lps.loss_coating IS NOT NULL

ORDER BY jo_number, stage;


-- ============================================================
--  VIEW 5: vw_production_volume
--
--  Grain: one row per batch (job order)
--
--  Purpose:
--    Provides batch-level production volume data. Powers:
--      Card 1  — total batches processed
--      Card 2  — total units processed (SUM batch_size)
--      Chart 1 — batches per month (trend)
--      Chart 2 — units per month (trend)
--      Chart 3 — units by dosage form
--      Chart 4 — top 10 generics by units produced
--
--  Why anchored to dry_blending stage?
--    Every batch passes through compounding — it's the only
--    stage guaranteed to have one and exactly one row in
--    fact_batch_production. Joining to any other stage would
--    drop batches that skipped that stage (e.g. capsules
--    skipping compression).
--
--  Fan-out prevention:
--    By filtering fact_batch_production to stage = 'dry_blending',
--    each batch appears exactly once. Without this filter,
--    joining to all stages would multiply batch_size by the
--    number of stages (3-5x), inflating all volume metrics.
--
--  batch_count = 1:
--    Each row = one batch. SUM(batch_count) over any filter
--    = total batches. Simpler in DAX than DISTINCTCOUNT(jo_id)
--    for most visuals, though both are correct.
--
--  date_key: YYYYMMDD integer of compounding date.
--    Uses dim_date.date_id directly (already an integer)
--    rather than converting from a DATE string.
-- ============================================================

CREATE VIEW vw_production_volume AS

SELECT
    -- Identifiers
    djo.jo_id,
    djo.jo_number,
    dp.product_name,
    dp.generic_name,
    dp.dosage_form,

    -- Volume measure
    djo.batch_size,

    -- Batch counter flag
    1 AS batch_count,

    -- Half-year segment for H1/H2 analysis in Power BI
    CASE
        WHEN dd.month <= 6 THEN 'H1'
        ELSE 'H2'
    END AS half_year,

    -- Date key only — year/month/quarter from vw_dim_date join
    dd.date_id AS date_key

FROM dim_job_order djo
JOIN dim_product dp
    ON djo.product_id = dp.product_id
JOIN fact_batch_production fbp
    ON djo.jo_id  = fbp.jo_id
   AND fbp.stage  = 'dry_blending'
LEFT JOIN dim_date dd
    ON fbp.date_id = dd.date_id

ORDER BY dd.date_id, dp.generic_name;