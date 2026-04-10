-- ============================================================
--  VIEW 1 (REVISED): vw_machine_utilization
--
--  KEY CHANGE FROM v1:
--  v1 was fully aggregated (one row per machine per stage, no dates).
--  v2 adds a monthly grain: one row per machine per stage per month.
--  This is required for MoM and rolling average DAX measures to work.
--  Without a date column, time intelligence functions have nothing
--  to iterate over.
--
--  Grain: machine × stage × year × month
-- ============================================================
DROP VIEW IF EXISTS vw_machine_utilization;
CREATE VIEW vw_machine_utilization AS
 
WITH stage_targets AS (
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
 
-- New in v2: aggregate by machine + stage + month instead of
-- machine + stage only. This gives Power BI a date axis to work
-- with for time intelligence while keeping the same analytical logic.
machine_monthly AS (
    SELECT
        dm.machine_id,
        dm.machine_name,
        dm.machine_type,
        fbp.stage,
        -- date_key: first day of the month as YYYYMMDD integer.
        -- We use the 1st of the month as the anchor because machine
        -- utilization is naturally a monthly aggregate, not a daily one.
        -- Power BI's time intelligence functions (DATESMTD, DATEADD)
        -- need a date column to iterate over — this provides it.
        CAST(
            dd.year * 10000
            + dd.month * 100
            + 1
        AS INT)                                     AS date_key,
 
        COUNT(*)                                    AS batch_count,
        ROUND(AVG(fbp.yield_pct * 100), 2)         AS avg_yield_pct,
        ROUND(MIN(fbp.yield_pct * 100), 2)         AS min_yield_pct,
        ROUND(MAX(fbp.yield_pct * 100), 2)         AS max_yield_pct,
        ROUND(STDDEV(fbp.yield_pct * 100), 2)      AS stddev_yield_pct,
        COUNT(*) FILTER (WHERE fbp.yield_pct IS NOT NULL) AS yield_recorded_count
 
    FROM fact_batch_production fbp
    JOIN dim_machine dm ON fbp.machine_id  = dm.machine_id
    JOIN dim_date   dd  ON fbp.date_id     = dd.date_id
    WHERE fbp.machine_id IS NOT NULL
      AND fbp.yield_pct  IS NOT NULL
    GROUP BY
        dm.machine_id, dm.machine_name, dm.machine_type,
        fbp.stage, dd.year, dd.month
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
    ROUND(st.avg_target_pct, 2)                    AS target_yield_pct,
    ROUND(mm.avg_yield_pct - st.avg_target_pct, 2) AS yield_gap,
    CASE
        WHEN mm.avg_yield_pct >= st.avg_target_pct THEN 'AT OR ABOVE TARGET'
        ELSE 'BELOW TARGET'
    END                                             AS target_status
FROM machine_monthly mm
LEFT JOIN stage_targets st ON mm.stage::TEXT = st.stage::TEXT
ORDER BY mm.date_key, mm.stage, mm.batch_count DESC;