# 💊 LLI Pharmaceutical Manufacturing Analytics
### End-to-End EDA Portfolio | Batch Production Data | 2025

---

## 📌 Project Overview

This project is a complete, end-to-end data analytics system built on real anonymized pharmaceutical batch manufacturing data from a **Pharmaceutical Manufacturing Company**. It transforms raw Excel batch records into a structured PostgreSQL star schema and delivers a 7-module exploratory data analysis (EDA) portfolio covering production volume, product performance, machine utilization, lead time, yield efficiency, material loss, and market demand inference.

The project was built to demonstrate manufacturing-domain data analytics capabilities as part of a portfolio transition from Senior Process Lead to Data Analyst.

---

## 🧰 Tech Stack

| Layer | Tools |
|---|---|
| Data Extraction & Transformation | Python 3.11, pandas, numpy |
| Database | PostgreSQL (star schema) |
| ORM / DB Connection | SQLAlchemy, psycopg2, python-dotenv |
| Analysis | pandas, SQL (CTEs, window functions, aggregations) |
| Visualization | Plotly Express, Plotly Graph Objects |
| Environment | JupyterLab, VS Code, Conda (`datastack`) |
| Version Control | Git, GitHub |

---

## 📁 Project Structure

```
LLI-Data-Analysis/
├── .env                          # DB credentials (not committed)
├── .gitignore
├── README.md
├── data/
│   └── raw/                      # Source Excel file (not committed)
├── notebooks/
│   ├── ETL.ipynb                 # Development ETL notebook
│   ├── module_1.ipynb            # Production Volume Analysis
│   ├── module_2.ipynb            # Product Analysis
│   ├── module_3.ipynb            # Machine Utilization Analysis
│   ├── module_4.ipynb            # Lead Time Analysis
│   ├── module_5.ipynb            # Yield Analysis
│   ├── module_6.ipynb            # Loss Analysis
│   └── module_7.ipynb            # Market Demand Inference
├── src/
│   └── etl.py                    # Production ETL script
└── sql_queries/
    ├── schema.sql                # Full star schema DDL
    └── analytical_queries.sql    # Module SQL queries
```

---

## 🗄️ Database Schema

PostgreSQL star schema with 6 tables and **5,320 fact rows** (one row per stage per batch).

```
dim_product        — 233 unique products
dim_machine        — 23 machines across 5 stage types
dim_date           — 2,922 rows (2023–2030, pre-populated)
dim_job_order      — 1,064 batch job orders
dim_stage_target   — 21 internal yield targets
fact_batch_production — 5,320 rows (5 stages × 1,064 batches)
```

**Stages tracked:**
`wet_granulation` → `dry_blending` → `compression` → `coating` / `encapsulation`

**Key design decisions:**
- One row per stage per batch in the fact table — enables stage-level analysis without pivoting
- Two compounding sub-stages (`wet_granulation`, `dry_blending`) to reflect the actual two-machine process
- Nullable FKs for machine and date — accommodates batches processed outside
- Versioned yield targets via `effective_date` — supports historical gap analysis
- Upsert-safe loaders using `ON CONFLICT` — idempotent pipeline

---

## ⚙️ ETL Pipeline

The production ETL script (`src/etl.py`) handles the full Extract → Transform → Load cycle.

**Key features:**
- `.env` credential management — no hardcoded passwords
- `engine.begin()` transactions — atomic loads with rollback on failure
- Duplicate-safe loaders — `ON CONFLICT DO UPDATE` for all dimension tables
- Three-tier yield imputation — Derived → Group Mean → Global Mean fallback
- GMP-compliant anomaly flagging — yields above 100% are flagged, never silently dropped
- Business-logic-driven null handling — `DONE` / `NOT REQUIRED` / `PROCESSED OUTSIDE`
- `pd.melt()` wide-to-tall transformation for fact table loading
- Validation gate — pipeline stops if critical data issues are found

**Data quality issues resolved:**

| # | Issue | Resolution |
|---|---|---|
| 1 | Inconsistent text casing | `.str.upper()` standardization |
| 2 | Timestamp noise in date columns | `.dt.normalize()` to date-only |
| 3 | Whitespace masking nulls in yield columns | `pd.to_numeric(errors='coerce')` |
| 4 | Comma decimal + % sign in coating yield | Custom `normalize_yield_column()` |
| 5 | Yields above 100% | Flagged with `flag_cmpdg_above_100`, `flag_encap_above_100` |
| 6 | Semantic duplicates in generic names | Correction dictionary via `.replace()` |
| 7 | Non-breaking space `\xa0` in generic names | Detected via `repr()`, corrected upstream |

---

## 📊 EDA Modules — Summary

### Module 1 — Production Volume Analysis
**Business Question:** How much are we producing and when?

| Question | Key Finding |
|---|---|
| Monthly batch count | Q3 peaks (Aug: 116, Sep: 120); June dip from 3-week audit |
| Quarterly output | Q3 highest at 81.9M units; Q2 lowest at 52.6M |
| Output by dosage form | Film-Coated Tablet dominates at 51.2% of total output |

**Recommendation:** Pre-build inventory in Q1 to buffer Q2 audit downtime and Q3 surge.

---

### Module 2 — Product Analysis
**Business Question:** What are we making and how well?

| Question | Key Finding |
|---|---|
| Top 10 generics by output | Atorvastatin Calcium leads at 33.7M units |
| Top generics by batch count | Butamirate Citrate leads with 239 batches |
| Yield underperformance | Several generics exceed 50% below-96%-yield batch rate |

**Recommendation:** Investigate high-frequency generics with disproportionate yield underperformance — separate product issues from machine issues.

---

### Module 3 — Machine Utilization Analysis
**Business Question:** How are our machines being used and how well are they performing?

| Question | Key Finding |
|---|---|
| Batch count per machine | G1 (451), ZP-41 (366), KEVIN 48 (441) are stage workhorses |
| Average yield by machine | PHARMAFILL (95.44%) is below the 97% encapsulation target across 94 batches |
| Frequency vs yield relationship | Encapsulation is the only stage where higher frequency = lower yield |

**Top Priority Finding:** PHARMAFILL is the highest-priority maintenance concern across all stages — most-used encapsulation machine, consistently below target, inverse frequency-yield relationship. Conduct tooling and fill weight consistency review immediately.

---

### Module 4 — Lead Time Analysis
**Business Question:** How long does it take to get a product ready for packaging?

| Question | Key Finding |
|---|---|
| Lead time by dosage form | Enteric-Coated Tablet longest at 17 days; Capsule fastest at 4.9 days |
| Monthly lead time trend | Peaks in Feb (12.8d) and Aug (13d); drops to 4.2d in December |
| Longest lead time generics | Levetiracetam at 27.1 days — only generic exceeding 21-day SLA |
| 21-day SLA compliance | Film-Coated Tablet (87.9%) and Bilayer Tablet (88.2%) are below target |

**Recommendation:** Apply tiered SLA targets by dosage form. Investigate Film-Coated Tablet scheduling bottlenecks — at 51% of production volume, its 12.1% SLA breach rate represents a large absolute number of delayed batches.

---

### Module 5 — Yield Analysis
**Business Question:** How efficiently are we converting raw materials?

| Question | Key Finding |
|---|---|
| Average yield per stage | All stages above 96% minimum; Encapsulation lowest at 96.39% |
| Yield by dosage form & stage | Bilayer Tablet coating worst at 91.85%; Enteric-Coated compression at 95.05% |
| Monthly yield trend | Encapsulation dips below 96% target in Jan, May, Aug, Sep |
| Batches below target | Encapsulation: 40.8% below target; Coating: 24.9%; Compression: 23.3% |

**Key Insight:** A 40.8% below-target batch rate for encapsulation is masked by an acceptable average. Average yield monitoring alone is insufficient — batch-level compliance rates must be tracked alongside averages.

---

### Module 6 — Loss Analysis
**Business Question:** Where are we losing material and how much?

Material loss was calculated using the **stage input-output chain** — each stage's input is the previous stage's output, not the original batch size.

```
loss_units = previous_stage_output × (1 - current_stage_yield)
```

| Question | Key Finding |
|---|---|
| Total loss per stage | Coating: 4.95M units; Compression: 3.87M; Total facility: ~13.1M units |
| Loss by dosage form | Film-Coated Tablet: 7.13M units (54% of total loss) |
| Top generics by loss | Atorvastatin Calcium: 2.02M; Butamirate Citrate: 1.34M; Mefenamic Acid: 1.06M |
| Monthly loss trend | September peak at 369,190 units aligns with Q3 production surge |

**Key Insight:** Coating has a better yield percentage than encapsulation but generates more absolute loss — because it processes far more volume. Yield % and absolute loss units tell different stories and both must be reported.

---

### Module 7 — Market Demand Inference
**Business Question:** What does production data tell us about the market?

Production patterns are used as a **proxy signal for external market demand** — what the facility produces reflects what clients are ordering.

| Question | Key Finding |
|---|---|
| Seasonal pattern by dosage form | Dual peaks in Jan and Sep for Film-Coated Tablets; aligns with rainy season demand |
| H1 vs H2 production growth | Telmisartan +266.7%; Paracetamol +142.9%; Ciprofloxacin HCL +125% |
| Concentration risk (Pareto) | Top 5 generics = ~43% of output; Atorvastatin Calcium alone = 11.74% |

**Recommendation:** Telmisartan, Paracetamol, and Ciprofloxacin HCL are high-priority products for 2026 capacity planning. Flag Atorvastatin Calcium as a single-product dependency risk — assess whether it is covered by long-term supply agreements.

---

## 🔑 Key Skills Demonstrated

### Python & Data Engineering
- Production-grade ETL pipeline with modular function architecture
- `pd.melt()` for wide-to-tall transformation of multi-stage batch data
- Multi-tier imputation logic with audit trail flags
- GMP-compliant data handling — anomalies flagged, never silently dropped
- Idempotent pipeline design using upsert patterns

### SQL
- Star schema design with custom ENUM types
- Window functions — `ROW_NUMBER()`, `SUM() OVER()`, cumulative Pareto
- CTEs for multi-step analytical queries
- Conditional aggregation — `MAX(CASE WHEN stage = 'x' THEN value END)`
- Stage input-output chain modeled entirely in SQL

### Data Analysis
- Domain-informed EDA — manufacturing process logic drives analytical decisions
- Separating volume-driven findings from efficiency-driven findings
- Distinguishing average yield from batch-level compliance rates
- Lead time SLA analysis with dosage-form-specific benchmarking
- Market demand inference from production proxy data

### Visualization (Plotly)
- Horizontal and vertical bar charts with target reference lines
- Multi-series line charts for trend analysis
- Scatter plots for frequency-yield relationship analysis
- Stacked bar charts for SLA compliance breakdown
- Dual-axis Pareto chart using `plotly.graph_objects`

### Communication
- Every analytical finding structured as: **Observation → Insight → Recommendation**
- Insights written at plant manager / operations head level
- Separation of statistically meaningful findings from low-sample artifacts
- All findings documented in markdown for portfolio presentation

---

## 📈 Top 5 Portfolio-Worthy Findings

1. **PHARMAFILL encapsulation machine** — highest-frequency machine, below-target yield, inverse frequency-yield relationship. A 40.8% below-target batch rate masked by an acceptable stage-level average. Classic example of how aggregate metrics hide operational problems.

2. **Film-Coated Tablet SLA breach** — 12.1% of batches exceed the 21-day lead time target. At 51.2% of total production volume, this translates to a high absolute number of delayed batches. Identifies KEVIN 48 coating machine as a scheduling single point of failure.

3. **Yield % vs absolute loss distinction** — Coating has better yield than encapsulation but generates the most absolute unit loss (4.95M units) due to production volume. Demonstrates that percentage-based KPIs alone can mislead operational decisions.

4. **Levetiracetam lead time outlier** — 27.1-day average vs 21-day SLA, the only generic with a statistically meaningful SLA breach. Identified using a minimum 5-batch filter to separate signal from noise.

5. **Telmisartan demand surge** — 266.7% H1-to-H2 production growth signals a major market demand shift for antihypertensives. Provides a data-driven basis for 2026 raw material procurement and capacity planning.

---

## ⚠️ Data Anonymization

This portfolio uses **anonymized data** in compliance with GMP data integrity principles:
- Generic names (INN — International Nonproprietary Names) are used instead of proprietary product names
- Job order IDs (`jo_id`) replace actual job order numbers
- Lot numbers are excluded from all portfolio outputs
- The raw Excel source file is excluded from version control via `.gitignore`

---

## 👤 Author

**Joshua Nieva**
Senior Process Lead → Data Analyst
Licensed Chemical Engineer | B.S. Chemical Engineering, Cum Laude — Bicol University
DOST-SEI Scholar

*Built with Python, PostgreSQL, Plotly, and JupyterLab*
*Mentored and developed in collaboration with Claude (Anthropic)*