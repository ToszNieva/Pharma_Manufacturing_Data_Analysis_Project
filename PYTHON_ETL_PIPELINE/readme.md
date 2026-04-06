# Pharmaceutical Batch Manufacturing — ETL Pipeline

A Python ETL pipeline that pulls raw pharmaceutical batch manufacturing data from Excel, cleans and transforms it, and loads it into a PostgreSQL star schema database.

This is part of a larger manufacturing analytics project built on real plant data from a solid dosage form facility.

---

## What it does

The pipeline runs in three main stages:

**Extract** — reads a flat Excel file containing batch manufacturing records (compounding, compression, encapsulation, and coating data all in one row per batch).

**Transform** — cleans and standardizes the raw data before loading. This includes fixing inconsistent text casing, stripping timestamp noise from date columns, handling messy yield values (comma decimals, percentage signs), filling in missing remarks using manufacturing business logic, and imputing missing yield values using a three-tier approach.

**Load** — inserts cleaned data into five PostgreSQL tables using upsert logic, so the pipeline can be re-run safely without creating duplicate records.

---

## Data quality problems solved

The source data came from a manually maintained Excel file, so there were several issues to work through:

| Problem | What was done |
|---|---|
| Inconsistent text casing in remarks and machine columns | Standardized everything to uppercase |
| Excel timestamps stored with time components | Stripped to date only using `.dt.normalize()` |
| Whitespace masking null values in yield columns | Used `pd.to_numeric(errors='coerce')` to convert to proper nulls |
| Yield column with comma decimals and `%` sign (e.g. `96,21%`) | Custom cleaning function to strip and convert |
| Yields above 100% (data entry errors) | Flagged with boolean columns — not corrected, in line with GMP data integrity principles |
| Semantic duplicates in generic drug names (e.g. `ATORVASTATIN (AS CALCIUM)` vs `ATORVASTATIN CALCIUM`) | Corrected upstream in the transform step using a corrections dictionary |
| Non-breaking spaces (`\xa0`) in text fields from copy-paste | Handled in the same generic name standardization step |
| Bilayer tablets sharing the same JO Number across two layers | Deduplication logic uses both `JO Number` AND `Product Name` to avoid dropping valid bilayer rows |

---

## Yield imputation — three-tier approach

For batches marked as `DONE` but with a missing yield value, the pipeline tries to fill it in using this order:

1. **Derive** — calculate from `actual_output / batch_size` if both values exist
2. **Group mean** — use the mean yield for the same product and batch size
3. **Global mean** — fall back to the overall column mean if group mean is unavailable

Each row is flagged as `RECORDED`, `DERIVED`, or `IMPUTED` so it's always clear which values were original and which were estimated.

---

## Remarks logic

Not every batch goes through every stage. The pipeline fills in missing remarks based on manufacturing rules:

- **Compression** — not required for capsule products
- **Encapsulation** — only required for capsule products
- **Coating** — not required for plain tablets, capsules, and bilayer tablets
- If a stage was done but remarks are missing → filled as `DONE`
- If a stage is not applicable for that dosage form → filled as `NOT REQUIRED`
- If no date and no applicable rule → filled as `PROCESSED OUTSIDE`

There is also a product-level exception: one specific SR tablet product does not require coating despite its dosage form normally requiring it. This is handled separately in the coating remarks logic.

---

## Pipeline architecture

```
etl.py
├── get_engine()                    — connects to PostgreSQL using .env credentials
├── test_connection()               — validates connection before running
├── extract_raw_data()              — reads Excel file
├── transform_data()                — orchestrates all cleaning steps
│   ├── uppercase_columns()
│   ├── normalize_date_columns()
│   ├── normalize_yield_column()
│   ├── fill_remarks()
│   ├── impute_yield()
│   └── standardize_generic_names()
├── remove_duplicates()             — removes true duplicates, preserves bilayer rows
├── validate_data()                 — checks for critical data issues before loading
├── load_dim_product()              — upsert loader
├── load_dim_machine()              — upsert loader
├── load_dim_date()                 — upsert loader (pre-populates 2023–2030)
├── load_dim_job_order()            — upsert loader with FK resolution
├── load_fact_batch_production()    — melt + upsert loader
└── main()                          — runs the full pipeline
```

The flat Excel structure (one row per batch) is transformed into a tall format (one row per stage per batch) using `pd.melt()` before loading into the fact table.

---

## Setup

**Requirements**

```
pandas
numpy
sqlalchemy
psycopg2-binary
python-dotenv
openpyxl
```

Install with:

```bash
pip install pandas sqlalchemy psycopg2-binary python-dotenv openpyxl
```

**Environment variables**

Create a `.env` file in the project root:

```
DB_USER=your_username
DB_PASSWORD=your_password
DB_HOST=localhost
DB_PORT=5432
DB_NAME=lli_db
RAW_DATA_PATH=data/raw/your_source_file.xlsx
```

**Run the pipeline**

```bash
python src/etl.py
```

---

## Design decisions worth noting

**Upsert over insert** — all loaders use `ON CONFLICT ... DO UPDATE` so the pipeline can be re-run after new data is added without creating duplicates or throwing errors.

**Validation gate** — the pipeline checks for critical data issues (missing JO numbers, product names, dosage forms, batch sizes) before any data is loaded. If issues are found, the pipeline stops and prints a report.

**GMP-aligned data handling** — yields above 100% are flagged rather than corrected. In a regulated manufacturing environment, recorded values should not be silently modified. The flags allow analysts to investigate while preserving the original data.

**Upstream fixes** — generic name inconsistencies are corrected in the transform step, not patched after loading. This keeps the database clean without needing post-load UPDATE scripts.

**Atomic transactions** — all dimension and fact loads run inside a single `engine.begin()` transaction block. If anything fails mid-load, the whole transaction rolls back.

**Two machine columns for compounding** — the compounding stage uses two machines: a granulator for wet granulation and a blender for final mixing. These are tracked separately using `machine_id` and `blending_machine_id` in the fact table.

---

## Database statistics after full load

| Table | Rows |
|---|---|
| dim_product | 233 |
| dim_machine | 23 |
| dim_date | 2,922 |
| dim_job_order | 1,064 |
| fact_batch_production | 4,256 |
