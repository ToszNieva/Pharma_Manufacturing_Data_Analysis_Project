# Pharmaceutical Batch Manufacturing — PostgreSQL Star Schema

A star schema database designed for pharmaceutical batch manufacturing analytics. Built to support stage-level yield analysis, machine utilization tracking, and production trend reporting across multiple dosage forms.

This schema is the storage layer for the `LLI-Data-Analysis` project. Data is loaded by the ETL pipeline in `src/etl.py`.

---

## Schema overview

```
                         ┌──────────────────┐
                         │  dim_stage_target│
                         │  (yield targets) │
                         └──────────────────┘

┌─────────────┐     ┌──────────────────────────┐     ┌──────────────┐
│  dim_product│◄────│  fact_batch_production   │────►│  dim_machine │
└─────────────┘     │  (one row per stage      │     └──────────────┘
                    │   per batch)             │
┌─────────────┐     │                          │     ┌──────────────┐
│dim_job_order│◄────│  jo_id, product_id,      │────►│   dim_date   │
└─────────────┘     │  machine_id,             │     └──────────────┘
                    │  blending_machine_id,    │
                    │  date_id, stage,         │
                    │  yield_pct, ...          │
                    └──────────────────────────┘
```

---

## Tables

### fact_batch_production

The central fact table. One row per stage per batch.

A single batch job order with three active stages (compounding, compression, coating) will produce three rows in this table — one for each stage. This structure makes stage-level analysis straightforward without needing to pivot or unnest data in queries.

| Column | Type | Notes |
|---|---|---|
| fact_id | SERIAL PK | Auto-generated |
| jo_id | INT FK | References dim_job_order |
| product_id | INT FK | References dim_product |
| machine_id | INT FK | Nullable — NULL for external batches |
| blending_machine_id | INT FK | Nullable — compounding blender only |
| date_id | INT FK | Nullable — NULL for external batches |
| stage | stage_name ENUM | compounding, compression, coating, encapsulation |
| actual_output_units | NUMERIC | Units produced at this stage |
| yield_pct | NUMERIC(6,4) | Stored as decimal — 0.9750 = 97.50% |
| batch_size | NUMERIC | Planned batch size in units |

`yield_pct` is stored as a decimal proportion (0.0 to 1.0). Multiply by 100 in the reporting layer for display. The check constraint allows values up to 1.5 to accommodate raw material overages that occasionally appear in compounding — these are flagged in the ETL rather than corrected.

The compounding stage uses two machines: a granulator for wet granulation and a blender for final mixing. These are tracked separately using `machine_id` and `blending_machine_id`. For all other stages, `blending_machine_id` is NULL.

---

### dim_product

One row per unique product. A product is uniquely identified by the combination of `product_name`, `generic_name`, and `dosage_form` — the same generic drug can appear multiple times under different brand names or strengths.

| Column | Type | Notes |
|---|---|---|
| product_id | SERIAL PK | |
| product_name | VARCHAR(255) | Brand/trade name |
| generic_name | VARCHAR(255) | INN drug name |
| dosage_form | dosage_form ENUM | |

---

### dim_machine

One row per unique machine. Tracks the machine's function within its stage using `machine_type`.

| machine_type | Stage | Description |
|---|---|---|
| granulator | compounding | Wet granulation |
| blender | compounding | Final mixing / blending |
| tabletting | compression | Tablet compression |
| coater | coating | Pan coating |
| encapsulation | encapsulation | Capsule filling |

`is_active` supports soft deletes — decommissioned machines are marked inactive rather than deleted. This preserves historical fact records that reference those machines.

---

### dim_date

Pre-populated continuous date table covering 2023-01-01 to 2030-12-31. `date_id` uses YYYYMMDD integer format (e.g. `20240315`) for compact joins.

The continuous date range is important for Power BI — time intelligence functions like year-to-date and rolling averages require a gap-free date table to work correctly.

---

### dim_job_order

One row per batch job order. `lot_number` is nullable because not all batches have a lot number recorded at the time of data entry.

---

### dim_stage_target

Reference table for internal yield targets per stage and dosage form. Current targets:

| Stage | Target |
|---|---|
| Compounding | 98% (all dosage forms) |
| Compression | 97% (tablet-forming forms only) |
| Encapsulation | 97% (capsule only) |
| Coating | 96% (film, SR, ER, enteric, modified release) |

Uses `effective_date` for version history. When targets change, a new row is inserted instead of overwriting the old one. Gap analysis queries join on `stage + dosage_form + MAX(effective_date)` to get the target that was applicable at the time of production.

---

## ENUM types

Two custom ENUM types enforce consistent categorical values:

**stage_name** — `compounding`, `compression`, `coating`, `encapsulation`

**dosage_form** — `CAPSULE`, `FILM-COATED TABLET`, `TABLET`, `SUSTAINED-RELEASE TABLET`, `EXTENDED RELEASE TABLET`, `BILAYER TABLET`, `ENTERIC-COATED TABLET`, `MODIFIED RELEASE TABLET`

Any new dosage form or production stage needs to be added to the ENUM before new data can be loaded.

---

## Sample queries

**Monthly batch count by dosage form**
```sql
SELECT
    d.year,
    d.month_name,
    p.dosage_form,
    COUNT(DISTINCT f.jo_id) AS batch_count
FROM fact_batch_production f
JOIN dim_date d ON f.date_id = d.date_id
JOIN dim_product p ON f.product_id = p.product_id
WHERE f.stage = 'compounding'
GROUP BY d.year, d.month, d.month_name, p.dosage_form
ORDER BY d.year, d.month;
```

**Average yield vs target by stage**
```sql
SELECT
    f.stage,
    ROUND(AVG(f.yield_pct) * 100, 2)        AS avg_yield_pct,
    MAX(t.target_yield_pct)                  AS target_pct,
    ROUND(AVG(f.yield_pct) * 100, 2)
        - MAX(t.target_yield_pct)            AS gap
FROM fact_batch_production f
JOIN dim_product p ON f.product_id = p.product_id
JOIN dim_stage_target t
    ON f.stage = t.stage
    AND p.dosage_form = t.dosage_form
WHERE f.yield_pct IS NOT NULL
GROUP BY f.stage
ORDER BY gap;
```

**Machine utilization — batch count per machine**
```sql
SELECT
    m.machine_name,
    m.machine_type,
    m.stage,
    COUNT(f.fact_id) AS batches_processed
FROM fact_batch_production f
JOIN dim_machine m ON f.machine_id = m.machine_id
GROUP BY m.machine_name, m.machine_type, m.stage
ORDER BY batches_processed DESC;
```

**Top 10 generics by total output**
```sql
SELECT
    p.generic_name,
    p.dosage_form,
    SUM(f.actual_output_units) AS total_units
FROM fact_batch_production f
JOIN dim_product p ON f.product_id = p.product_id
WHERE f.actual_output_units IS NOT NULL
GROUP BY p.generic_name, p.dosage_form
ORDER BY total_units DESC
LIMIT 10;
```

---

## Design decisions

**One row per stage per batch** — the source data has one row per batch with columns for each stage side by side. Storing it that way works for simple lookups but makes stage-level analysis harder. The ETL uses `pd.melt()` to reshape it into one row per stage, which makes queries much cleaner.

**Nullable FKs for machine and date** — batches processed at external facilities have no machine or date recorded. Rather than forcing a placeholder value, these are stored as NULL with appropriate constraints.

**Upsert-safe unique constraints** — every table has a unique constraint that the ETL targets with `ON CONFLICT`. This means the pipeline can be re-run any number of times without creating duplicates.

**Soft deletes on dim_machine** — marking machines as inactive instead of deleting them keeps historical fact records intact. A deleted machine_id would break foreign key constraints on old fact rows.

**Yield stored as decimal, checked up to 1.5** — the `yield_pct` check constraint is set to allow values up to 1.5 rather than 1.0. Compounding yields occasionally exceed 100% due to moisture absorption or raw material variations. The ETL flags these but does not correct them, in line with GMP data integrity principles.

---

## Database statistics

| Table | Rows | Description |
|---|---|---|
| dim_product | 233 | Unique products |
| dim_machine | 23 | Machines across 5 types |
| dim_date | 2,922 | Pre-populated 2023–2030 |
| dim_job_order | 1,064 | Batch job orders |
| dim_stage_target | 21 | Yield targets by stage and dosage form |
| fact_batch_production | 4,256 | One row per stage per batch |

---

## How to use

Run the schema DDL against a PostgreSQL database named `lli_db`:

```bash
psql -d lli_db -f sql_queries/schema.sql
```

Then run the ETL pipeline to load data:

```bash
python src/etl.py
```