-- ============================================================
--  VIEW 3: vw_lead_time
--
--  One row per job order (batch).
--  Answers: How many days from compounding to final stage?
--  Which batches breached the 21-day SLA?
--  Used for: Page 4 (Lead Time & Loss dashboard)
-- ============================================================
 
CREATE OR REPLACE VIEW vw_lead_time AS
 
WITH stage_dates AS (
    -- Pivot the fact table from tall (one row per stage) to wide
    -- (one row per batch, one column per stage date).
    -- We use MAX(CASE WHEN) conditional aggregation — a classic SQL pivot.
    -- MAX() works here because each jo_id + stage is unique (UNIQUE constraint
    -- on fact table), so MAX() just picks the one existing value.
    SELECT
        fbp.jo_id,
        MAX(CASE WHEN fbp.stage = 'wet_granulation'
            THEN dd.full_date END)                AS compounding_date,
        MAX(CASE WHEN fbp.stage = 'compression'
            THEN dd.full_date END)                AS compression_date,
        MAX(CASE WHEN fbp.stage = 'encapsulation'
            THEN dd.full_date END)                AS encapsulation_date,
        MAX(CASE WHEN fbp.stage = 'coating'
            THEN dd.full_date END)                AS coating_date
    FROM fact_batch_production fbp
    LEFT JOIN dim_date dd ON fbp.date_id = dd.date_id
    GROUP BY fbp.jo_id
),
 
lead_time_calc AS (
    -- Compute lead time per batch using dosage-form-specific end stage.
    -- Business rule: lead time ends at the LAST applicable production stage.
    --   Capsule         → encapsulation date
    --   Film-Coated, SR, ER, Enteric, Modified → coating date
    --   Tablet, Bilayer → compression date (no coating required)
    -- COALESCE handles cases where a stage date is missing (PROCESSED OUTSIDE).
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
 
        -- Final stage date based on dosage form
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
            ELSE sd.compression_date   -- TABLET, BILAYER TABLET
        END AS final_stage_date,
 
        -- Lead time in days (final stage − compounding start)
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
 
    -- Date components for time intelligence in Power BI
    EXTRACT(YEAR  FROM ltc.compounding_date)::INT  AS year,
    EXTRACT(MONTH FROM ltc.compounding_date)::INT  AS month,
    TO_CHAR(ltc.compounding_date, 'Month')         AS month_name,
    EXTRACT(QUARTER FROM ltc.compounding_date)::INT AS quarter,
 
    -- SLA compliance (21-day internal benchmark)
    CASE
        WHEN ltc.lead_time_days IS NULL     THEN 'INCOMPLETE DATA'
        WHEN ltc.lead_time_days <= 21       THEN 'WITHIN SLA'
        ELSE 'SLA BREACH'
    END                                             AS sla_status,
 
    -- Binary flag for Power BI measure: SLA breach rate
    CASE
        WHEN ltc.lead_time_days IS NOT NULL
         AND ltc.lead_time_days > 21               THEN 1
        ELSE 0
    END                                             AS is_sla_breach
 
FROM lead_time_calc ltc
WHERE ltc.compounding_date IS NOT NULL
ORDER BY ltc.jo_number;