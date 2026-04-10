# Pharmaceutical Manufacturing Data Analysis Project

## Background

This project was built as part of a career transition from pharmaceutical manufacturing (Senior Process Lead) into data analytics. The domain knowledge behind the analytical decisions — yield targets, GMP data handling, stage-level process flow — comes directly from working in a regulated solid dosage manufacturing environment.

The analysis is meant to answer questions that matter to plant operations: where are we losing yield, which machines are carrying the most load, and how does production volume shift across the year.

An end-to-end data analytics project built on real batch manufacturing data from a solid dosage form pharmaceutical facility. This covers the full pipeline — from raw Excel records to a structured PostgreSQL database and a 7-module exploratory data analysis portfolio.

The goal of this project is to show how manufacturing data can be turned into useful insights for production planning, yield monitoring, and machine performance tracking.

> **Note on data privacy:** Product names and job order numbers have been anonymized. Generic drug names (INN) are used throughout in place of proprietary brand names. Raw source data is excluded from this repository.

---

## What's in this repo

```
Pharma_Manufacturing_Data_Analysis_Project/
├── PYTHON_ETL_PIPELINE/        # Data pipeline — Extract, Transform, Load
├── SQL_STAR_SCHEMA_DATABASE/   # PostgreSQL star schema design
├── EDA_ANALYSIS/               # 7-module exploratory data analysis notebooks
└── README.md
```

---

## Project Breakdown

### Python ETL Pipeline
A Python pipeline that reads raw Excel batch records, cleans and transforms the data, and loads it into a PostgreSQL star schema. Handles real-world data quality issues like inconsistent casing, messy yield values, missing remarks, and semantic duplicates in drug names.

**Key features:** upsert-safe loaders, three-tier yield imputation, GMP-aligned data flagging, atomic transactions, idempotent pipeline design.

See the [ETL README](./PYTHON_ETL_PIPELINE/readme.md) for full details.

---

### SQL Star Schema Database
A PostgreSQL star schema designed for stage-level manufacturing analysis. One row per stage per batch in the fact table — this makes yield and machine queries much cleaner compared to the original flat Excel structure.

**Tables:** `fact_batch_production`, `dim_product`, `dim_machine`, `dim_date`, `dim_job_order`, `dim_stage_target`

See the [Schema README](./SQL_STAR_SCHEMA_DATABASE/readme.md) for full details.

---

### EDA Analysis ✅
Seven-module exploratory data analysis built entirely in Python (pandas + Plotly) with SQL queries against the PostgreSQL star schema. Every analytical finding is structured as Observation → Insight → Recommendation, written at plant manager / operations head level.

| Module | Topic | Status |
|---|---|---|
| 1 | Production Volume Analysis | ✅ Complete |
| 2 | Product Analysis | ✅ Complete |
| 3 | Machine Utilization Analysis | ✅ Complete |
| 4 | Lead Time Analysis | ✅ Complete |
| 5 | Yield Analysis | ✅ Complete |
| 6 | Loss Analysis | ✅ Complete |
| 7 | Market Demand Inference | ✅ Complete |

See the [EDA README](./EDA_ANALYSIS/README.md) for full analysis details, key findings, and stakeholder recommendations.

---

## Dataset Overview

| Item | Detail |
|---|---|
| Source | Flat Excel batch manufacturing records |
| Records | 1,064 batches |
| Dosage forms | 8 types (film-coated tablet, capsule, SR tablet, tablet, bilayer tablet, extended release, enteric-coated, modified release) |
| Stages tracked | Wet Granulation, Dry Blending, Compression, Encapsulation, Coating |
| Date range | 2025 |
| Fact table rows | 5,320 (one row per stage per batch) |

---

## Key Findings

**Machine Performance**
- PHARMAFILL encapsulation machine operates below the 97% yield target across 94 batches — the highest-priority maintenance finding in the project. Higher usage corresponds to lower yield, the only stage where this inverse relationship was observed.
- KEVIN 48 coating machine handles 63% of all coating batches — a single point of failure risk for the facility's highest-volume dosage form.

**Yield & Loss**
- 40.8% of encapsulation batches fall below the 97% yield target — masked by an acceptable stage-level average. Batch-level compliance rates tell a fundamentally different story than averages alone.
- Total facility material loss: ~13.1 million units across all stages in 2025. Coating generates the highest absolute loss (4.95M units) despite having a better yield percentage than encapsulation — because volume amplifies small inefficiencies.
- Atorvastatin Calcium alone accounts for 2.02M units of material loss, the highest of any generic.

**Lead Time**
- Levetiracetam averages 27.1 days — the only generic with a statistically meaningful breach of the 21-day SLA.
- Film-Coated Tablet has a 12.1% SLA breach rate. At 51.2% of total production volume, this translates to a large absolute number of delayed batches.

**Market Demand**
- Telmisartan production grew 266.7% from H1 to H2 2025 — signaling a major antihypertensive demand surge requiring 2026 capacity planning attention.
- Top 5 generics represent ~43% of total output. Atorvastatin Calcium alone accounts for 11.74% — a single-product dependency risk.

---

## Tech Stack

| Tool | Purpose |
|---|---|
| Python 3.11 | ETL pipeline, EDA |
| pandas, numpy | Data transformation and analysis |
| SQLAlchemy, psycopg2 | Database connection and loading |
| PostgreSQL | Star schema database |
| Plotly Express / Graph Objects | EDA visualizations |
| python-dotenv | Credential management |
| Git / GitHub | Version control |

---

## How to Run the Pipeline

**1. Clone the repo**
```bash
git clone https://github.com/ToszNieva/Pharma_Manufacturing_Data_Analysis_Project.git
cd Pharma_Manufacturing_Data_Analysis_Project
```

**2. Set up your environment**
```bash
conda create -n datastack python=3.11
conda activate datastack
pip install pandas numpy sqlalchemy psycopg2-binary plotly python-dotenv openpyxl
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
python PYTHON_ETL_PIPELINE/etl_pipeline.py
```

**6. Open the EDA notebooks**
```bash
jupyter lab
```
Navigate to `EDA_ANALYSIS/` and run the modules in order.

---

## Author

**Joshua Nieva**
Senior Process Lead → Data Analyst
Licensed Chemical Engineer | B.S. Chemical Engineering, Cum Laude — Bicol University
DOST-SEI Scholar

[GitHub](https://github.com/ToszNieva)

