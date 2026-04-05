-- ============================================================
--  PHARMACEUTICAL MANUFACTURING
--  Database : lli_db (PostgreSQL)
--  Author   : Joshua Nieva. | Senior Process Lead → Data Analyst
--  Version  : 1.0
--  Updated  : 2025
--
--  Description:
--    Production analytics schema for pharmaceutical batch manufacturing
--    Transforms flat Excel batch records into
--    a normalized star schema supporting stage-level yield
--    analysis, machine utilization, and trend reporting.
--
--  Schema design:
--    - One row per stage per batch in fact_batch_production
--    - Upsert-safe: all loaders use ON CONFLICT targeting the
--      unique constraints defined here
--    - Nullable FKs for machine_id / date_id accommodate
--      batches processed outside (no machine or date recorded)
--    - Two machine FK columns in fact table support compounding
--      stage which uses both a granulator and a blender
--    - Soft deletes on dim_machine preserve historical records
--    - dim_date pre-populated 2023–2030 for Power BI continuity
--    - dim_stage_target supports versioned yield gap analysis
-- ============================================================


-- ============================================================
--  ENUMS
--  Enforces consistent categorical values across the schema.
--  Any new dosage form or stage must be added here first.
-- ============================================================

CREATE TYPE stage_name AS ENUM (
    'compounding',
    'compression',
    'coating',
    'encapsulation'
);

CREATE TYPE dosage_form AS ENUM (
    'CAPSULE',
    'FILM-COATED TABLET',
    'TABLET',
    'SUSTAINED-RELEASE TABLET',
    'EXTENDED RELEASE TABLET',
    'BILAYER TABLET',
    'ENTERIC-COATED TABLET',
    'MODIFIED RELEASE TABLET'
);


-- ============================================================
--  DIMENSION: dim_product
--  One row per unique product (name + generic + dosage form).
--  A single generic drug may appear multiple times under
--  different brand names or strengths — the composite unique
--  constraint captures all three attributes.
--
--  ETL upsert target: UNIQUE (product_name, generic_name, dosage_form)
--  On conflict      : DO UPDATE generic_name
-- ============================================================

CREATE TABLE dim_product (
    product_id   SERIAL       PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    generic_name VARCHAR(255) NOT NULL,
    dosage_form  dosage_form  NOT NULL,
    created_at   TIMESTAMP    DEFAULT NOW(),

    CONSTRAINT uq_product UNIQUE (product_name, generic_name, dosage_form)
);


-- ============================================================
--  DIMENSION: dim_machine
--  One row per unique machine name.
--  machine_type classifies function within a stage:
--    granulator   → wet granulation (compounding)
--    blender      → final mixing (compounding)
--    tabletting   → compression
--    coater       → coating
--    encapsulation → encapsulation
--  is_active supports soft deletes — decommissioned machines
--  are retained to preserve historical fact records.
--
--  ETL upsert target: UNIQUE (machine_name)
--  On conflict      : DO UPDATE machine_type, stage
-- ============================================================

CREATE TABLE dim_machine (
    machine_id   SERIAL       PRIMARY KEY,
    machine_name VARCHAR(255) NOT NULL UNIQUE,
    machine_type VARCHAR(50)  NOT NULL,
    stage        stage_name   NOT NULL,
    is_active    BOOLEAN      DEFAULT TRUE,
    created_at   TIMESTAMP    DEFAULT NOW(),

    CONSTRAINT chk_machine_type CHECK (
        machine_type IN ('granulator', 'blender', 'tabletting', 'coater', 'encapsulation')
    )
);


-- ============================================================
--  DIMENSION: dim_date
--  Pre-populated continuous date table (2023-01-01 to 2030-12-31).
--  date_id uses YYYYMMDD integer format for compact FK joins.
--  Continuous range ensures Power BI time intelligence functions
--  (YTD, MTD, rolling averages) work without gaps.
--
--  ETL upsert target: PRIMARY KEY (date_id)
--  On conflict      : DO NOTHING
-- ============================================================

CREATE TABLE dim_date (
    date_id      INT          PRIMARY KEY,   -- YYYYMMDD (e.g. 20240315)
    full_date    DATE         NOT NULL UNIQUE,
    year         SMALLINT     NOT NULL,
    quarter      SMALLINT     NOT NULL  CHECK (quarter BETWEEN 1 AND 4),
    month        SMALLINT     NOT NULL  CHECK (month BETWEEN 1 AND 12),
    month_name   VARCHAR(10)  NOT NULL,
    week_number  SMALLINT     NOT NULL,
    day_of_week  SMALLINT     NOT NULL  CHECK (day_of_week BETWEEN 1 AND 7),
    day_name     VARCHAR(10)  NOT NULL,
    is_weekend   BOOLEAN      NOT NULL
);


-- ============================================================
--  DIMENSION: dim_job_order
--  One row per batch / job order.
--  lot_number is nullable — not all batches have a lot number
--  recorded at the time of data entry.
--
--  ETL upsert target: UNIQUE (jo_number)
--  On conflict      : DO UPDATE batch_size, lot_number, product_id
-- ============================================================

CREATE TABLE dim_job_order (
    jo_id      SERIAL         PRIMARY KEY,
    jo_number  VARCHAR(50)    NOT NULL UNIQUE,
    batch_size NUMERIC(10, 0) NOT NULL CHECK (batch_size > 0),
    lot_number VARCHAR(50),
    product_id INT            NOT NULL REFERENCES dim_product (product_id),
    created_at TIMESTAMP      DEFAULT NOW()
);


-- ============================================================
--  DIMENSION: dim_stage_target  (Reference / Lookup)
--  Internal yield targets per stage per dosage form.
--  effective_date enables version history — when targets change,
--  a new row is inserted rather than overwriting the old record.
--  Gap analysis queries JOIN on stage + dosage_form + MAX(effective_date)
--  to retrieve the target applicable at the time of production.
--
--  Targets (current):
--    Compounding   → 98% across all dosage forms
--    Compression   → 97% (tablet-forming forms only)
--    Encapsulation → 97% (capsule only)
--    Coating       → 96% (film, SR, ER, enteric, modified release)
--
--  ETL: static reference data — loaded once via INSERT, not upserted.
-- ============================================================

CREATE TABLE dim_stage_target (
    target_id        SERIAL        PRIMARY KEY,
    stage            stage_name    NOT NULL,
    dosage_form      dosage_form   NOT NULL,
    target_yield_pct NUMERIC(5, 2) NOT NULL CHECK (target_yield_pct BETWEEN 0 AND 100),
    effective_date   DATE          NOT NULL DEFAULT CURRENT_DATE,
    notes            TEXT,

    CONSTRAINT uq_stage_target UNIQUE (stage, dosage_form, effective_date)
);


-- ============================================================
--  FACT TABLE: fact_batch_production
--  One row per stage per batch (jo_id + stage = natural key).
--  A single job order with 3 active stages generates 3 rows.
--
--  yield_pct stored as decimal proportion (0.0 – 1.0):
--    e.g. 97.5% is stored as 0.9750
--    CHECK constraint enforces 0 ≤ yield_pct ≤ 1
--    Multiply by 100 in reporting layer for display.
--
--  machine_id / blending_machine_id are nullable:
--    NULL = batch processed outside, no machine recorded.
--  date_id is nullable:
--    NULL = batch processed outside, no date recorded.
--
--  Two machine FK columns for compounding:
--    machine_id         → granulator (wet granulation)
--    blending_machine_id → blender (final mixing)
--  For all other stages, blending_machine_id is NULL.
--
--  ETL upsert target: UNIQUE (jo_id, stage)
--  On conflict      : DO UPDATE all measure and FK columns
-- ============================================================

CREATE TABLE fact_batch_production (
    fact_id             SERIAL         PRIMARY KEY,

    -- Foreign keys
    jo_id               INT            NOT NULL  REFERENCES dim_job_order (jo_id),
    product_id          INT            NOT NULL  REFERENCES dim_product (product_id),
    machine_id          INT                      REFERENCES dim_machine (machine_id),
    blending_machine_id INT                      REFERENCES dim_machine (machine_id),
    date_id             INT                      REFERENCES dim_date (date_id),

    -- Stage identity
    stage               stage_name     NOT NULL,

    -- Measures
    actual_output_units NUMERIC(10, 0) CHECK (actual_output_units >= 0),
    yield_pct           NUMERIC(6, 4)  CHECK (yield_pct BETWEEN 0 AND 1.5),  -- decimal proportion: 0.9750 = 97.50%; values >1.0 indicate raw material overages
    batch_size          NUMERIC(10, 0) CHECK (batch_size >= 0),

    -- Audit
    created_at          TIMESTAMP      DEFAULT NOW(),
    source_file         VARCHAR(255),

    CONSTRAINT uq_fact UNIQUE (jo_id, stage)
);


-- ============================================================
--  REFERENCE DATA: dim_stage_target seed values
-- ============================================================

INSERT INTO dim_stage_target (stage, dosage_form, target_yield_pct, notes) VALUES
    -- Compounding (all dosage forms, 98%)
    ('compounding', 'FILM-COATED TABLET',       98.00, 'Standard target'),
    ('compounding', 'TABLET',                   98.00, 'Standard target'),
    ('compounding', 'CAPSULE',                  98.00, 'Standard target'),
    ('compounding', 'SUSTAINED-RELEASE TABLET', 98.00, 'Standard target'),
    ('compounding', 'EXTENDED RELEASE TABLET',  98.00, 'Standard target'),
    ('compounding', 'BILAYER TABLET',            98.00, 'Standard target'),
    ('compounding', 'ENTERIC-COATED TABLET',     98.00, 'Standard target'),
    ('compounding', 'MODIFIED RELEASE TABLET',   98.00, 'Standard target'),

    -- Compression (tablet-forming forms only; capsule not applicable)
    ('compression', 'FILM-COATED TABLET',        97.00, 'Standard target'),
    ('compression', 'TABLET',                    97.00, 'Standard target'),
    ('compression', 'SUSTAINED-RELEASE TABLET',  97.00, 'Standard target'),
    ('compression', 'EXTENDED RELEASE TABLET',   97.00, 'Standard target'),
    ('compression', 'BILAYER TABLET',             97.00, 'Standard target'),
    ('compression', 'ENTERIC-COATED TABLET',      97.00, 'Standard target'),
    ('compression', 'MODIFIED RELEASE TABLET',    97.00, 'Standard target'),

    -- Encapsulation (capsule only)
    ('encapsulation', 'CAPSULE', 97.00, 'Standard target'),

    -- Coating (film, SR, ER, enteric, modified release only)
    ('coating', 'FILM-COATED TABLET',        96.00, 'Standard target'),
    ('coating', 'SUSTAINED-RELEASE TABLET',  96.00, 'Standard target'),
    ('coating', 'EXTENDED RELEASE TABLET',   96.00, 'Standard target'),
    ('coating', 'ENTERIC-COATED TABLET',      96.00, 'Standard target'),
    ('coating', 'MODIFIED RELEASE TABLET',    96.00, 'Standard target');