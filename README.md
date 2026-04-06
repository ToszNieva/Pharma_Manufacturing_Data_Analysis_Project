# Pharmaceutical Manufacturing Data Analysis Project

## Background

This project was built as part of a career transition from pharmaceutical manufacturing (Senior Process Lead) into data analytics. The domain knowledge behind the analytical decisions — yield targets, GMP data handling, stage-level process flow — comes directly from working in a regulated solid dosage manufacturing environment.

The analysis is meant to answer questions that matter to plant operations: where are we losing yield, which machines are carrying the most load, and how does production volume shift across the year.


An end-to-end data analytics project built on real batch manufacturing data from a solid dosage form pharmaceutical facility. This covers the full pipeline — from raw Excel records to a structured database, exploratory analysis, and a management dashboard.

The goal of this project is to show how manufacturing data can be turned into useful insights for production planning, yield monitoring, and machine performance tracking.

> **Note on data privacy:** Product names and job order numbers have been anonymized. Generic drug names (INN) are used throughout in place of proprietary brand names. Raw source data is excluded from this repository.

---

## What's in this repo

```
Pharma_Manufacturing_Data_Analysis_Project/
├── Python_ETL_SCRIPT/          # Data pipeline — Extract, Transform, Load
├── SQL_STAR_SCHEMA_DATABASE/   # PostgreSQL star schema design
├── EDA_PORTFOLIO/              # Exploratory data analysis notebooks (in progress)
└── DASHBOARD/                  # Power BI management dashboard (in progress)
```

---

## Project breakdown

### Python ETL Script
A Python pipeline that reads raw Excel batch records, cleans and transforms the data, and loads it into a PostgreSQL star schema. Handles real-world data quality issues like inconsistent casing, messy yield values, missing remarks, and semantic duplicates in drug names.

**Key features:** upsert-safe loaders, three-tier yield imputation, GMP-aligned data flagging, atomic transactions.

See the [ETL README](./Python_ETL_SCRIPT/README.md) for full details.

---

### SQL Star Schema Database
A PostgreSQL star schema designed for stage-level manufacturing analysis. One row per stage per batch in the fact table — this makes yield and machine queries much cleaner compared to the original flat Excel structure.

**Tables:** `fact_batch_production`, `dim_product`, `dim_machine`, `dim_date`, `dim_job_order`, `dim_stage_target`

See the [Schema README](./SQL_STAR_SCHEMA_DATABASE/README.md) for full details.

---

### EDA Portfolio *(in progress)*
Exploratory data analysis notebooks covering seven analysis areas:

| Module | Topic | Status |
|---|---|---|
| 1 | Production Volume Analysis | Done |
| 2 | Product Analysis | In progress |
| 3 | Machine Utilization Analysis | Planned |
| 4 | Lead Time Analysis | Planned |
| 5 | Yield Analysis | Planned |
| 6 | Loss Analysis | Planned |
| 7 | Market Demand Inference | Planned |

---

### Dashboard *(in progress)*
A Power BI management dashboard connected to the PostgreSQL database. Designed for operations and plant management — covering production volume, yield performance, and machine utilization in a single view.

---

## Dataset overview

| Item | Detail |
|---|---|
| Source | Flat Excel batch manufacturing records |
| Records | 1,064 batches |
| Dosage forms | 8 types (film-coated tablet, capsule, SR tablet, tablet, bilayer tablet, extended release, enteric-coated, modified release) |
| Stages tracked | Compounding, compression, encapsulation, coating |
| Date range | 2025 |
| Fact table rows | 4,256 (one row per stage per batch) |

---

## Tech stack

| Tool | Purpose |
|---|---|
| Python 3.11 | ETL pipeline, EDA |
| pandas, numpy | Data transformation |
| SQLAlchemy, psycopg2 | Database connection and loading |
| PostgreSQL | Star schema database |
| Plotly | EDA visualizations |
| Power BI | Management dashboard |
| python-dotenv | Credential management |

---

## How to run the pipeline

**1. Clone the repo**
```bash
git clone https://github.com/ToszNieva/Pharma_Manufacturing_Data_Analysis_Project.git
cd Pharma_Manufacturing_Data_Analysis_Project
```

**2. Set up your environment**
```bash
conda env create -f environment.yml
conda activate datastack
```

**3. Set up your .env file**
```
DB_USER=your_username
DB_PASSWORD=your_password
DB_HOST=localhost
DB_PORT=5432
DB_NAME=lli_db
RAW_DATA_PATH=path/to/your/source_file.xlsx
```

**4. Create the database schema**
```bash
psql -d lli_db -f SQL_STAR_SCHEMA_DATABASE/lli_database_schema.sql
```

**5. Run the ETL pipeline**
```bash
python Python_ETL_SCRIPT/etl_pipeline.py
```

---
