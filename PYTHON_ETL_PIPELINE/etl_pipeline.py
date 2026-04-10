import os
import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, String, text
from sqlalchemy.engine.url import URL


# -----------------------------------------------------------------------------
# Database Connection
# -----------------------------------------------------------------------------
def get_env_var(name):
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def get_engine():
    load_dotenv()

    db_url = URL.create(
        drivername="postgresql",
        username=get_env_var("DB_USER"),
        password=get_env_var("DB_PASSWORD"),
        host=get_env_var("DB_HOST"),
        port=int(get_env_var("DB_PORT")),
        database=get_env_var("DB_NAME"),
    )

    return create_engine(db_url)


def test_connection(engine):
    with engine.connect() as conn:
        conn.exec_driver_sql("SELECT 1")
    print("Database connection successful")


# -----------------------------------------------------------------------------
# Extract
# -----------------------------------------------------------------------------
def extract_raw_data(file_path):
    print(f"Reading raw data from: {file_path}")
    df = pd.read_excel(file_path)
    return df


# -----------------------------------------------------------------------------
# Transform Helpers
# -----------------------------------------------------------------------------
def uppercase_columns(df, columns):
    existing_cols = [col for col in columns if col in df.columns]
    for col in existing_cols:
        df[col] = df[col].astype("string").str.upper()
    return df


def normalize_date_columns(df, columns):
    existing_cols = [col for col in columns if col in df.columns]
    for col in existing_cols:
        df[col] = pd.to_datetime(df[col], errors="coerce").dt.normalize()
    return df


def normalize_yield_column(series):
    cleaned = (
        series.astype("string")
        .str.strip()
        .str.replace(",", ".", regex=False)
        .str.replace("%", "", regex=False)
    )

    numeric = pd.to_numeric(cleaned, errors="coerce")

    # Convert obvious percentage-style entries like 95 into 0.95
    numeric = numeric.where(numeric <= 10, numeric / 100)

    return numeric


def fill_remarks(row, date_col, not_required_forms=None, not_required_products=None):
    if pd.notna(row[date_col]):
        return "DONE"
    elif not_required_forms and row["Dosage Form"] in not_required_forms:
        return "NOT REQUIRED"
    elif not_required_products and row["Product Name"] in not_required_products:
        return "NOT REQUIRED"
    else:
        return "PROCESSED OUTSIDE"


def impute_yield(df, yield_col, actual_col, remarks_col):
    flag_col = yield_col + "_impute_flag"
    df[flag_col] = "RECORDED"

    mask = (df[remarks_col] == "DONE") & (df[yield_col].isna())

    # Tier 1 — derive from actual output and batch size
    can_derive = mask & df[actual_col].notna() & df["Batch Size"].notna()
    df.loc[can_derive, yield_col] = (
        df.loc[can_derive, actual_col] / df.loc[can_derive, "Batch Size"]
    )
    df.loc[can_derive, flag_col] = "DERIVED"

    # Tier 2 — group-based mean imputation
    can_impute = mask & df[yield_col].isna()

    if can_impute.sum() > 0:
        product_batch_mean = df.groupby(["Product Name", "Batch Size"])[yield_col].transform("mean")
        product_mean = df.groupby(["Product Name"])[yield_col].transform("mean")
        global_mean = df[yield_col].mean()

        df.loc[can_impute, yield_col] = (
            product_batch_mean[can_impute]
            .fillna(product_mean[can_impute])
            .fillna(global_mean)
        )
        df.loc[can_impute, flag_col] = "IMPUTED"

    return df


def standardize_generic_names(df):
    corrections = {
        "ATORVASTATIN (AS CALCIUM)": "ATORVASTATIN CALCIUM",
        "CHOLECALCIFEROL (VITAMIN D3) ": "CHOLECALCIFEROL (VITAMIN D3)",
        "METHYLDOPA\xa0(AS SESQUIHYDRATE)": "METHYLDOPA (AS SESQUIHYDRATE)",
    }
    df["Generic"] = df["Generic"].replace(corrections)
    return df


# -----------------------------------------------------------------------------
# Transform
# -----------------------------------------------------------------------------
def transform_data(df):
    df_clean = df.copy()

    remarks_columns = [
        "Compounding Remarks",
        "Compression Remarks",
        "Encapsulation Remarks",
        "Coating REMARKS",
    ]

    machine_columns = [
        "Compression Machine Used",
        "Encapsulation Machine Used",
        "Coating Machine Used",
    ]

    date_columns = [
        "Compounding Date",
        "Compression Date",
        "Encapsulation Date",
        "Coating Date",
    ]

    # Standardize text columns
    df_clean = uppercase_columns(df_clean, remarks_columns)
    df_clean = uppercase_columns(df_clean, machine_columns)

    # Normalize dates
    df_clean = normalize_date_columns(df_clean, date_columns)

    # Clean yield columns
    df_clean["% Yield_Cmprsn"] = pd.to_numeric(df_clean["% Yield_Cmprsn"], errors="coerce")
    df_clean["% Yield_Ctng"] = normalize_yield_column(df_clean["% Yield_Ctng"])

    # Flags for yields above 100%
    df_clean["flag_cmpdg_above_100"] = df_clean["% Yield_Cmpdg"] > 1.0
    df_clean["flag_encap_above_100"] = df_clean["% Yield_Encap"] > 1.0

    # Build exclusion lists
    all_dosage_forms = df_clean["Dosage Form"].dropna().unique().tolist()
    not_required_encapsulation = [f for f in all_dosage_forms if f != "CAPSULE"]
    not_required_compression = ["CAPSULE"]
    not_required_coating = ["TABLET", "CAPSULE", "BILAYER TABLET"]

    # Fill remarks using business logic
    mask = df_clean["Compression Remarks"] != "DONE"
    df_clean.loc[mask, "Compression Remarks"] = df_clean.loc[mask].apply(
        fill_remarks,
        axis=1,
        date_col="Compression Date",
        not_required_forms=not_required_compression,
    )

    mask = df_clean["Encapsulation Remarks"] != "DONE"
    df_clean.loc[mask, "Encapsulation Remarks"] = df_clean.loc[mask].apply(
        fill_remarks,
        axis=1,
        date_col="Encapsulation Date",
        not_required_forms=not_required_encapsulation,
    )

    mask = df_clean["Coating REMARKS"] != "DONE"
    df_clean.loc[mask, "Coating REMARKS"] = df_clean.loc[mask].apply(
        fill_remarks,
        axis=1,
        date_col="Coating Date",
        not_required_forms=not_required_coating,
        not_required_products=["KALIGEN POTASSIUM CHLORIDE SUSTAINED-RELEASE TABLET 750 MG"],
    )

    # Impute missing yields
    df_clean = impute_yield(df_clean, "% Yield_Cmprsn", "Compression Actual Yield", "Compression Remarks")
    df_clean = impute_yield(df_clean, "% Yield_Encap", "Encapsulation Actual Yield", "Encapsulation Remarks")
    df_clean = impute_yield(df_clean, "% Yield_Ctng", "Coating Actual Yield", "Coating REMARKS")

    # Standardize generic names (upstream fix for semantic duplicates)
    df_clean = standardize_generic_names(df_clean)

    return df_clean


# -----------------------------------------------------------------------------
# Remove Duplicates
# -----------------------------------------------------------------------------
def remove_duplicates(df):
    """
    Removes duplicate rows based on BOTH JO Number and Product Name.

    Rationale: Bilayer tablets have two rows sharing the same JO Number —
    one row per layer — distinguished by the layer name in parentheses
    within the Product Name (e.g., "PRODUCT X (LAYER 1)"). These are
    NOT duplicates. A true duplicate requires both JO Number AND
    Product Name to match.
    """
    before = len(df)
    duplicated_mask = df.duplicated(subset=["JO Number", "Product Name"], keep=False)
    duplicated_rows = df[duplicated_mask]

    if len(duplicated_rows) == 0:
        print(f"remove_duplicates: No duplicates found ({before} rows retained)")
        return df

    duplicate_count = duplicated_mask.sum()
    print(f"remove_duplicates: {duplicate_count} rows share duplicate JO Number + Product Name")
    print("Affected rows:")
    print(duplicated_rows[["JO Number", "Product Name"]].to_string(index=False))

    df_deduped = df.drop_duplicates(subset=["JO Number", "Product Name"], keep="last").reset_index(drop=True)

    after = len(df_deduped)
    print(f"remove_duplicates: Dropped {before - after} duplicate rows → {after} rows remaining")

    return df_deduped


# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
def validate_data(df):
    print("\n=== DATA VALIDATION REPORT ===\n")

    issues_found = False

    # Critical fields check
    critical_fields = ["JO Number", "Product Name", "Dosage Form", "Batch Size"]
    critical_problems = df[df[critical_fields].isna().any(axis=1)]

    if len(critical_problems) == 0:
        print("✓ Critical fields: No issues found")
    else:
        print(f"✗ Critical fields missing: {len(critical_problems)} rows affected")
        print(critical_problems[["JO Number", "Product Name", "Dosage Form", "Batch Size"]].to_string(index=False))
        issues_found = True

    print()

    # Yield completeness checks for DONE stages
    checks = [
        {
            "label": "Compression yield missing but marked DONE",
            "remarks_col": "Compression Remarks",
            "yield_col": "% Yield_Cmprsn",
            "date_col": "Compression Date",
        },
        {
            "label": "Encapsulation yield missing but marked DONE",
            "remarks_col": "Encapsulation Remarks",
            "yield_col": "% Yield_Encap",
            "date_col": "Encapsulation Date",
        },
        {
            "label": "Coating yield missing but marked DONE",
            "remarks_col": "Coating REMARKS",
            "yield_col": "% Yield_Ctng",
            "date_col": "Coating Date",
        },
    ]

    for check in checks:
        problem_rows = df[
            (df[check["remarks_col"]] == "DONE") & (df[check["yield_col"]].isna())
        ]

        if len(problem_rows) == 0:
            print(f"✓ {check['label']}: No issues found")
        else:
            print(f"✗ {check['label']}: {len(problem_rows)} rows affected")
            print(
                problem_rows[
                    ["JO Number", "Product Name", check["remarks_col"], check["date_col"]]
                ].to_string(index=False)
            )
            print()
            issues_found = True

    return issues_found


# -----------------------------------------------------------------------------
# Dimension Loaders (with Upsert)
# -----------------------------------------------------------------------------
def load_dim_product(df, conn):
    dim_product = (
        df[["Product Name", "Generic", "Dosage Form"]]
        .drop_duplicates()
        .rename(columns={
            "Product Name": "product_name",
            "Generic": "generic_name",
            "Dosage Form": "dosage_form",
        })
    )

    upsert_sql = text("""
        INSERT INTO dim_product (product_name, generic_name, dosage_form)
        VALUES (:product_name, :generic_name, :dosage_form)
        ON CONFLICT (product_name, generic_name, dosage_form)
        DO UPDATE SET
            generic_name = EXCLUDED.generic_name
    """)

    conn.execute(upsert_sql, dim_product.to_dict(orient="records"))
    print(f"dim_product upserted: {len(dim_product)} rows processed")

    return dim_product


def load_dim_machine(df, conn):
    # Granulator (wet granulation machines)
    comp_wet = (
        df[["Compounding Wet"]].drop_duplicates().dropna()
        .rename(columns={"Compounding Wet": "machine_name"})
        .assign(stage="compounding", machine_type="granulator")
    )

    # Blender (final mixing machines)
    comp_dry = (
        df[["Compounding Final Mixing"]].drop_duplicates().dropna()
        .rename(columns={"Compounding Final Mixing": "machine_name"})
        .assign(stage="compounding", machine_type="blender")
    )

    # Compression (tabletting machines)
    cmprsn = (
        df[["Compression Machine Used"]].drop_duplicates().dropna()
        .rename(columns={"Compression Machine Used": "machine_name"})
        .assign(stage="compression", machine_type="tabletting")
    )

    # Encapsulation machines
    encap = (
        df[["Encapsulation Machine Used"]].drop_duplicates().dropna()
        .rename(columns={"Encapsulation Machine Used": "machine_name"})
        .assign(stage="encapsulation", machine_type="encapsulation")
    )

    # Coating machines
    ctng = (
        df[["Coating Machine Used"]].drop_duplicates().dropna()
        .rename(columns={"Coating Machine Used": "machine_name"})
        .assign(stage="coating", machine_type="coater")
    )

    dim_machine = pd.concat([comp_wet, comp_dry, cmprsn, encap, ctng], ignore_index=True)

    # Remove logbook entries / carryover entries (not real machine names)
    dim_machine = dim_machine[
        ~dim_machine["machine_name"]
        .astype("string")
        .str.contains("c/o|logbook", case=False, na=False)
    ]

    dim_machine = dim_machine.drop_duplicates(subset=["machine_name", "stage", "machine_type"])

    upsert_sql = text("""
        INSERT INTO dim_machine (machine_name, machine_type, stage)
        VALUES (:machine_name, :machine_type, :stage)
        ON CONFLICT (machine_name)
        DO UPDATE SET
            machine_type = EXCLUDED.machine_type,
            stage        = EXCLUDED.stage
    """)

    conn.execute(upsert_sql, dim_machine.to_dict(orient="records"))
    print(f"dim_machine upserted: {len(dim_machine)} rows processed")

    return dim_machine


def load_dim_date(conn):
    date_range = pd.date_range("2023-01-01", "2030-12-31", freq="D")

    records = [
        {
            "date_id": int(d.strftime("%Y%m%d")),
            "full_date": d.date(),
            "year": d.year,
            "quarter": d.quarter,
            "month": d.month,
            "month_name": d.strftime("%B"),
            "week_number": d.isocalendar().week,
            "day_of_week": d.isoweekday(),
            "day_name": d.strftime("%A"),
            "is_weekend": d.isoweekday() >= 6,
        }
        for d in date_range
    ]

    dim_date = pd.DataFrame(records)

    upsert_sql = text("""
        INSERT INTO dim_date (
            date_id, full_date, year, quarter, month,
            month_name, week_number, day_of_week, day_name, is_weekend
        )
        VALUES (
            :date_id, :full_date, :year, :quarter, :month,
            :month_name, :week_number, :day_of_week, :day_name, :is_weekend
        )
        ON CONFLICT (date_id)
        DO NOTHING
    """)

    conn.execute(upsert_sql, dim_date.to_dict(orient="records"))
    print(f"dim_date upserted: {len(dim_date)} rows processed")

    return dim_date


def load_dim_job_order(df, conn):
    dim_job_order = df[
        ["JO Number", "Product Name", "Generic", "Batch Size", "Lot No.", "Dosage Form"]
    ].drop_duplicates()

    dim_product_db = pd.read_sql(
        "SELECT product_id, product_name, generic_name, dosage_form FROM dim_product",
        conn,
    )

    dim_job_order = dim_job_order.merge(
        dim_product_db[["product_name", "generic_name", "dosage_form", "product_id"]],
        left_on=["Product Name", "Generic", "Dosage Form"],
        right_on=["product_name", "generic_name", "dosage_form"],
        how="inner",
    )

    dim_job_order = dim_job_order.drop(
        columns=["Product Name", "Generic", "Dosage Form", "product_name", "generic_name", "dosage_form"]
    ).rename(columns={
        "JO Number": "jo_number",
        "Batch Size": "batch_size",
        "Lot No.": "lot_number",
    })

    upsert_sql = text("""
        INSERT INTO dim_job_order (jo_number, batch_size, lot_number, product_id)
        VALUES (:jo_number, :batch_size, :lot_number, :product_id)
        ON CONFLICT (jo_number)
        DO UPDATE SET
            batch_size  = EXCLUDED.batch_size,
            lot_number  = EXCLUDED.lot_number,
            product_id  = EXCLUDED.product_id
    """)

    conn.execute(upsert_sql, dim_job_order.to_dict(orient="records"))
    print(f"dim_job_order upserted: {len(dim_job_order)} rows processed")

    return dim_job_order


# -----------------------------------------------------------------------------
# Fact Loader (with Upsert)
# -----------------------------------------------------------------------------
def load_fact_batch_production(df, conn):
    # Read dimension IDs from database
    dim_jo_db = pd.read_sql(
        "SELECT jo_id, jo_number, product_id, batch_size FROM dim_job_order",
        conn,
    )
    dim_machine_db = pd.read_sql(
        "SELECT machine_id, machine_name FROM dim_machine",
        conn,
    )

    # --- Build wet_granulation rows ---
    wet_gran = df[["JO Number", "Compounding Wet", "Compounding Date", "Batch Size"]].copy()
    wet_gran["stage"] = "wet_granulation"
    wet_gran["yield_pct"] = None        # no separate yield recorded for this sub-stage
    wet_gran["actual_output_units"] = None
    wet_gran = wet_gran.rename(columns={
        "Compounding Wet": "machine_name",
        "Compounding Date": "stage_date",
    })

    # --- Build dry_blending rows ---
    dry_blend = df[["JO Number", "Compounding Final Mixing", "Compounding Date", "Batch Size", "% Yield_Cmpdg"]].copy()
    dry_blend["stage"] = "dry_blending"
    dry_blend = dry_blend.rename(columns={
        "Compounding Final Mixing": "machine_name",
        "Compounding Date": "stage_date",
        "% Yield_Cmpdg": "yield_pct",
    })
    dry_blend["actual_output_units"] = None  # no separate actual output column for compounding

    # --- Build compression rows ---
    compression = df[["JO Number", "Compression Machine Used", "Compression Date",
                       "Batch Size", "% Yield_Cmprsn", "Compression Actual Yield"]].copy()
    compression["stage"] = "compression"
    compression = compression.rename(columns={
        "Compression Machine Used": "machine_name",
        "Compression Date": "stage_date",
        "% Yield_Cmprsn": "yield_pct",
        "Compression Actual Yield": "actual_output_units",
    })

    # --- Build encapsulation rows ---
    encapsulation = df[["JO Number", "Encapsulation Machine Used", "Encapsulation Date",
                         "Batch Size", "% Yield_Encap", "Encapsulation Actual Yield"]].copy()
    encapsulation["stage"] = "encapsulation"
    encapsulation = encapsulation.rename(columns={
        "Encapsulation Machine Used": "machine_name",
        "Encapsulation Date": "stage_date",
        "% Yield_Encap": "yield_pct",
        "Encapsulation Actual Yield": "actual_output_units",
    })

    # --- Build coating rows ---
    coating = df[["JO Number", "Coating Machine Used", "Coating Date",
                  "Batch Size", "% Yield_Ctng", "Coating Actual Yield"]].copy()
    coating["stage"] = "coating"
    coating = coating.rename(columns={
        "Coating Machine Used": "machine_name",
        "Coating Date": "stage_date",
        "% Yield_Ctng": "yield_pct",
        "Coating Actual Yield": "actual_output_units",
    })

    # --- Stack all stages into one tall DataFrame ---
    fact = pd.concat(
        [wet_gran, dry_blend, compression, encapsulation, coating],
        ignore_index=True
    )

    # --- Resolve date_id ---
    fact["date_id"] = (
        pd.to_datetime(fact["stage_date"], errors="coerce")
        .dt.strftime("%Y%m%d")
    )
    fact["date_id"] = pd.to_numeric(fact["date_id"], errors="coerce").astype("Int64")
    fact = fact.drop(columns=["stage_date"])

    # --- Resolve foreign keys ---
    fact = fact.merge(dim_jo_db, left_on="JO Number", right_on="jo_number", how="left")

    fact = fact.merge(
        dim_machine_db[["machine_name", "machine_id"]],
        on="machine_name",
        how="left",
    )

    # --- Final column selection ---
    fact_final = fact[[
        "jo_id",
        "product_id",
        "machine_id",
        "date_id",
        "stage",
        "actual_output_units",
        "yield_pct",
        "batch_size",
    ]].copy()

    # --- Fix data types ---
    int_cols = ["machine_id", "date_id", "batch_size", "actual_output_units"]
    for col in int_cols:
        fact_final[col] = pd.to_numeric(fact_final[col], errors="coerce").round(0).astype("Int64")

    fact_final["stage"] = fact_final["stage"].astype(str)

    # --- Upsert into fact table ---
    upsert_sql = text("""
        INSERT INTO fact_batch_production (
            jo_id, product_id, machine_id,
            date_id, stage, actual_output_units, yield_pct, batch_size
        )
        VALUES (
            :jo_id, :product_id, :machine_id,
            :date_id, :stage, :actual_output_units, :yield_pct, :batch_size
        )
        ON CONFLICT (jo_id, stage)
        DO UPDATE SET
            product_id          = EXCLUDED.product_id,
            machine_id          = EXCLUDED.machine_id,
            date_id             = EXCLUDED.date_id,
            actual_output_units = EXCLUDED.actual_output_units,
            yield_pct           = EXCLUDED.yield_pct,
            batch_size          = EXCLUDED.batch_size
    """)

    records = fact_final.where(pd.notna(fact_final), other=None).to_dict(orient="records")
    conn.execute(upsert_sql, records)
    print(f"fact_batch_production upserted: {len(fact_final)} rows processed")

    return fact_final


# -----------------------------------------------------------------------------
# Main Pipeline
# -----------------------------------------------------------------------------
def main():
    load_dotenv()

    file_path = os.getenv("RAW_DATA_PATH")

    engine = get_engine()
    test_connection(engine)

    df = extract_raw_data(file_path)

    df_clean = transform_data(df)

    df_clean = remove_duplicates(df_clean)

    issues_found = validate_data(df_clean)

    if issues_found:
        print("\nPipeline stopped: critical data issues found. Resolve before loading.")
        return

    with engine.begin() as conn:
        load_dim_product(df_clean, conn)
        load_dim_machine(df_clean, conn)
        load_dim_date(conn)
        load_dim_job_order(df_clean, conn)
        load_fact_batch_production(df_clean, conn)

    print("\nPipeline completed successfully!")


if __name__ == "__main__":
    main()