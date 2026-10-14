# Healthcare Patient Monitoring — Snowflake Data Pipeline

> **Educational project — fictional data only.**
> All patient records, device records, and measurements in this project are
> entirely synthetic. No real patient information is used. Numeric thresholds
> are illustrative examples and are **not** clinically validated.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Business Problem](#2-business-problem)
3. [Objectives and Features](#3-objectives-and-features)
4. [Technology Stack](#4-technology-stack)
5. [Architecture and Data Flow](#5-architecture-and-data-flow)
6. [Dataset Descriptions](#6-dataset-descriptions)
7. [Bronze Layer](#7-bronze-layer)
8. [Silver Layer](#8-silver-layer)
9. [Gold Layer](#9-gold-layer)
10. [Data Quality Rules](#10-data-quality-rules)
11. [Streams and Tasks Design](#11-streams-and-tasks-design)
12. [Repository Structure](#12-repository-structure)
13. [Setup and Execution Instructions](#13-setup-and-execution-instructions)
14. [Required Snowflake Privileges and Assumptions](#14-required-snowflake-privileges-and-assumptions)
15. [Validation and Testing Instructions](#15-validation-and-testing-instructions)
16. [Example Analytical Questions and Results](#16-example-analytical-questions-and-results)
17. [Known Limitations](#17-known-limitations)

---

## 1. Project Overview

This project builds an end-to-end data engineering pipeline using **Snowflake SQL**
that processes fictional healthcare patient monitoring data. The source data consists
of three CSV files containing patient demographics, device information, and time-series
physiological readings (heart rate, blood glucose, and oxygen saturation).

The pipeline implements the **Bronze–Silver–Gold Medallion Architecture**:

- **Bronze** — raw CSV data loaded as-is into Snowflake.
- **Silver** — cleaned, typed, validated, and deduplicated records.
- **Gold** — aggregated, analytics-ready tables for reporting and trend analysis.

Automation is added using **Snowflake Streams and Tasks** for incremental processing.

---

## 2. Business Problem

Healthcare monitoring systems produce large volumes of raw sensor and device data.
This data often arrives with quality problems — missing values, invalid readings,
duplicate records, and unknown device or patient references. Without a structured
pipeline, analysts cannot trust the data, queries become unreliable, and operational
decisions cannot be made with confidence.

This project demonstrates how to:
- Ingest raw data safely without losing invalid records.
- Systematically identify and isolate data quality problems.
- Produce clean, trusted analytical outputs.
- Automate the pipeline so new data is processed incrementally.

---

## 3. Objectives and Features

| Feature                                | Status |
|----------------------------------------|--------|
| Bronze raw ingestion via COPY INTO     | ✅     |
| Silver type casting and cleaning       | ✅     |
| Silver deduplication (deterministic)   | ✅     |
| Silver reference integrity validation  | ✅     |
| Silver plausibility range checks       | ✅     |
| CONTROL.REJECTED_RECORDS tracking      | ✅     |
| CONTROL.PIPELINE_RUN_LOG               | ✅     |
| CONTROL.DATA_QUALITY_LOG               | ✅     |
| CONTROL.QUALITY_THRESHOLDS (configurable) | ✅  |
| GOLD.DAILY_PATIENT_SUMMARY             | ✅     |
| GOLD.READING_ALERTS                    | ✅     |
| GOLD.PATIENT_TRENDS (with LAG)         | ✅     |
| Snowflake Streams + Tasks automation   | ✅     |
| SQL Reports and analytical queries     | ✅     |
| Test scripts with expected outcomes    | ✅     |
| Incremental batch loading scenario     | ✅     |

---

## 4. Technology Stack

| Component        | Technology                                    |
|------------------|-----------------------------------------------|
| Data warehouse   | Snowflake (Standard Edition or above)         |
| Transformations  | Snowflake SQL (MERGE, CTE, window functions)  |
| Source data      | CSV files (fictional/synthetic)               |
| Ingestion        | Snowflake internal stage + COPY INTO          |
| Incremental load | Snowflake Streams + Tasks                     |
| Version control  | Git + GitHub                                  |
| Development IDE  | VS Code with IBM Bob                          |

No Python, dbt, Snowpark, external cloud storage, APIs, or BI tools are used.

---

## 5. Architecture and Data Flow

```
CSV Files (data/)
    │
    ▼
Snowflake Internal Stage (BRONZE.HCM_STAGE)
    │  PUT command via SnowSQL or Snowsight
    ▼
Bronze Layer (BRONZE schema)
    RAW_PATIENTS  ─┐
    RAW_DEVICES   ─┤── COPY INTO (all columns VARCHAR)
    RAW_READINGS  ─┘
    │
    ▼
Silver Layer (SILVER schema)              ─────► CONTROL.REJECTED_RECORDS
    CLEAN_PATIENTS  (type cast + cleaned)
    CLEAN_DEVICES   (type cast + cleaned)
    CLEAN_READINGS  (validated, deduplicated)
    │
    ▼
Gold Layer (GOLD schema)
    DAILY_PATIENT_SUMMARY  (aggregation per patient per day)
    READING_ALERTS         (configurable threshold flags)
    PATIENT_TRENDS         (day-over-day LAG analysis)
    │
    ▼
SQL Reports (sql/07_reports/)
    Analytical query results
```

See [`docs/architecture.md`](docs/architecture.md) for the full Mermaid flowchart.

---

## 6. Dataset Descriptions

All data is **fictional and synthetic**. See [`data/DATA_DICTIONARY.md`](data/DATA_DICTIONARY.md)
for full column definitions, types, and known quality issues.

| File                   | Rows  | Description                                        |
|------------------------|-------|----------------------------------------------------|
| `data/patients.csv`    | 30    | Patient demographics (age, gender, city, reg date) |
| `data/devices.csv`     | 15    | Monitoring devices (type, manufacturer, status)    |
| `data/patient_readings.csv` | ~700 | Time-series readings (heart rate, glucose, SpO2) + intentional quality problems |

### Intentional Data Quality Problems in patient_readings.csv

| Problem Type                  | Example Row(s)         |
|-------------------------------|------------------------|
| Missing patient_id            | R0683                  |
| Unknown patient_id (P999)     | R0684                  |
| Non-numeric heart_rate (abc)  | R0685                  |
| Malformed timestamp           | R0686, R0700           |
| Negative heart_rate (-5)      | R0687                  |
| Oxygen saturation > 100 (115) | R0688                  |
| Heart rate > 180 (220)        | R0689                  |
| Unknown device_id (D999)      | R0690                  |
| Missing heart_rate (NULL)     | R0691                  |
| Missing oxygen_saturation     | R0692                  |
| Missing device_id             | R0693                  |
| Extreme glucose (2500 mg/dL)  | R0694                  |
| Exact duplicate rows          | R0695/R0696, R0680–R0682 |

---

## 7. Bronze Layer

**Schema:** `BRONZE`

**Tables:**
- `BRONZE.RAW_PATIENTS` — raw patient records
- `BRONZE.RAW_READINGS` — raw measurement readings
- `BRONZE.RAW_DEVICES` — raw device records

**Key design decisions:**
- All measurement columns in `RAW_READINGS` are `VARCHAR` to prevent COPY INTO
  failures when values like `abc` appear in numeric fields.
- Each row includes `_SOURCE_FILE VARCHAR` and `_INGESTION_TIMESTAMP TIMESTAMP_NTZ`
  for traceability back to the original load.
- COPY INTO uses `FORCE = FALSE` (default) to avoid double-loading files.
- The Bronze layer is append-only; records are never modified after load.

**SQL files:** [`sql/02_bronze/`](sql/02_bronze/)

---

## 8. Silver Layer

**Schema:** `SILVER`

**Tables:**
- `SILVER.CLEAN_PATIENTS`
- `SILVER.CLEAN_READINGS`
- `SILVER.CLEAN_DEVICES`

**Cleaning process:**
1. Type cast strings to `NUMBER`, `DATE`, `TIMESTAMP_NTZ` using `TRY_TO_*` functions.
2. Check mandatory fields for NULL.
3. Validate foreign keys against already-cleaned dimension tables.
4. Apply plausibility range checks using `CONTROL.QUALITY_THRESHOLDS`.
5. Deduplicate on `reading_id` (keep earliest timestamp).
6. Rejected records → `CONTROL.REJECTED_RECORDS`.
7. Valid records → Silver clean tables via `MERGE`.

**SQL files:** [`sql/03_silver/`](sql/03_silver/)

See [`docs/transformation_rules.md`](docs/transformation_rules.md) for full rule documentation.

---

## 9. Gold Layer

**Schema:** `GOLD`

**Tables:**

| Table                        | Description                                                         |
|------------------------------|---------------------------------------------------------------------|
| `GOLD.DAILY_PATIENT_SUMMARY` | One row per patient per day — averages, min/max, reading counts     |
| `GOLD.READING_ALERTS`        | Readings that triggered configurable threshold rules                |
| `GOLD.PATIENT_TRENDS`        | Day-over-day metric changes using LAG window function               |

**SQL files:** [`sql/04_gold/`](sql/04_gold/)

Gold tables are refreshed by the automation Tasks, or can be rebuilt manually
by running the Gold SQL scripts.

---

## 10. Data Quality Rules

Thresholds are stored in `CONTROL.QUALITY_THRESHOLDS` and are configurable.

| Metric               | Plausibility Range | Alert Threshold       |
|----------------------|--------------------|-----------------------|
| `heart_rate` (bpm)   | 40 – 180           | > 100 elevated, > 160 very high |
| `glucose_level` (mg/dL) | 50 – 600        | > 180 elevated, > 400 very high |
| `oxygen_saturation` (%) | 85 – 100        | < 92 low              |

> **Disclaimer:** These are illustrative examples only. Not clinically validated.

For the full rejection rule catalogue, see [`docs/transformation_rules.md`](docs/transformation_rules.md).
For the quality monitoring strategy, see [`docs/data_quality_strategy.md`](docs/data_quality_strategy.md).

---

## 11. Streams and Tasks Design

After the manual pipeline is validated, Snowflake Streams and Tasks automate
incremental processing of new readings.

**Task dependency chain:**
```
SILVER_INCREMENTAL_TASK (root, scheduled 15 min, WHEN stream has data)
    └─► GOLD_REFRESH_TASK
            └─► PIPELINE_LOG_TASK
```

- A **Stream** on `BRONZE.RAW_READINGS` captures all new inserts since the last
  task execution.
- The Silver task processes only the new rows, not the full table.
- The Gold task performs a targeted refresh for affected dates.
- Transaction boundaries ensure the stream offset only advances on successful commit.

**SQL files:** [`sql/05_automation/`](sql/05_automation/)

Full design details: [`docs/automation_design.md`](docs/automation_design.md)

---

## 12. Repository Structure

```
healthcare-patient-monitoring-snowflake/
├── README.md
├── data/
│   ├── patients.csv
│   ├── patient_readings.csv
│   ├── devices.csv
│   └── DATA_DICTIONARY.md
├── docs/
│   ├── architecture.md
│   ├── transformation_rules.md
│   ├── data_quality_strategy.md
│   └── automation_design.md
└── sql/
    ├── 01_setup/
    │   ├── 01_create_database_schemas.sql
    │   ├── 02_create_file_formats_stages.sql
    │   └── 03_create_control_tables.sql
    ├── 02_bronze/
    │   ├── 01_create_bronze_tables.sql
    │   └── 02_load_bronze_data.sql
    ├── 03_silver/
    │   ├── 01_create_silver_tables.sql
    │   ├── 02_load_silver_patients.sql
    │   ├── 03_load_silver_devices.sql
    │   └── 04_load_silver_readings.sql
    ├── 04_gold/
    │   ├── 01_create_gold_tables.sql
    │   ├── 02_load_gold_daily_summary.sql
    │   ├── 03_load_gold_reading_alerts.sql
    │   └── 04_load_gold_patient_trends.sql
    ├── 05_automation/
    │   ├── 01_create_stream.sql
    │   └── 02_create_tasks.sql
    ├── 06_testing/
    │   ├── 01_bronze_validation.sql
    │   ├── 02_silver_validation.sql
    │   ├── 03_gold_validation.sql
    │   ├── 04_reconciliation_checks.sql
    │   └── 05_incremental_batch_test.sql
    └── 07_reports/
        └── 01_analytical_queries.sql
```

---

## 13. Setup and Execution Instructions

### Prerequisites

- A Snowflake account (Standard Edition or above).
- A role with `SYSADMIN` or equivalent privileges.
- SnowSQL CLI **or** access to the Snowsight web UI.
- The files in `data/` available locally to upload.

### Step-by-Step Execution Order

> Run each SQL file in Snowsight (copy-paste) or via SnowSQL in the order listed.
> Scripts are numbered to make order explicit.

**Phase 1 — Setup**

```sql
-- 1. Create database and schemas
sql/01_setup/01_create_database_schemas.sql

-- 2. Create file format and internal stage
sql/01_setup/02_create_file_formats_stages.sql

-- 3. Create control tables and seed thresholds
sql/01_setup/03_create_control_tables.sql
```

**Phase 2 — Bronze**

```
-- Upload CSV files to the stage first (see Step below), then:
sql/02_bronze/01_create_bronze_tables.sql
sql/02_bronze/02_load_bronze_data.sql
```

**Uploading CSV files (SnowSQL):**
```bash
snowsql -a <your_account> -u <your_username>
PUT file:///path/to/data/patients.csv         @HEALTHCARE_MONITORING_DB.BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
PUT file:///path/to/data/patient_readings.csv @HEALTHCARE_MONITORING_DB.BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
PUT file:///path/to/data/devices.csv          @HEALTHCARE_MONITORING_DB.BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
```

**Phase 3 — Silver**
```
sql/03_silver/01_create_silver_tables.sql
sql/03_silver/02_load_silver_patients.sql
sql/03_silver/03_load_silver_devices.sql
sql/03_silver/04_load_silver_readings.sql
```

**Phase 4 — Gold**
```
sql/04_gold/01_create_gold_tables.sql
sql/04_gold/02_load_gold_daily_summary.sql
sql/04_gold/03_load_gold_reading_alerts.sql
sql/04_gold/04_load_gold_patient_trends.sql
```

**Phase 5 — Automation (optional, run after manual pipeline is verified)**
```
sql/05_automation/01_create_stream.sql
sql/05_automation/02_create_tasks.sql
-- Then resume tasks:
ALTER TASK PIPELINE_LOG_TASK RESUME;
ALTER TASK GOLD_REFRESH_TASK RESUME;
ALTER TASK SILVER_INCREMENTAL_TASK RESUME;
```

**Phase 6 — Testing**
```
sql/06_testing/01_bronze_validation.sql
sql/06_testing/02_silver_validation.sql
sql/06_testing/03_gold_validation.sql
sql/06_testing/04_reconciliation_checks.sql
sql/06_testing/05_incremental_batch_test.sql
```

**Phase 7 — Reports**
```
sql/07_reports/01_analytical_queries.sql
```

---

## 14. Required Snowflake Privileges and Assumptions

| Privilege / Assumption              | Details                                                          |
|-------------------------------------|------------------------------------------------------------------|
| `CREATE DATABASE`                   | Required to run the setup script. `SYSADMIN` has this.          |
| `CREATE SCHEMA`, `CREATE TABLE`     | Within the created database.                                     |
| `CREATE STAGE`, `CREATE FILE FORMAT`| Within the BRONZE schema.                                        |
| `CREATE TASK`, `CREATE STREAM`      | At the schema level. Tasks require `EXECUTE TASK` at account level. |
| `EXECUTE TASK`                      | Account-level privilege: `GRANT EXECUTE TASK ON ACCOUNT TO ROLE <role>;` |
| Warehouse availability              | A warehouse (e.g., `COMPUTE_WH`) must exist and be available.   |
| Snowflake edition                   | Standard Edition or above (Streams and Tasks require Standard+).|
| No external storage                 | Only Snowflake internal stage is used.                           |
| No Snowpark / Python                | All transformations are pure Snowflake SQL.                      |

---

## 15. Validation and Testing Instructions

Test scripts are in [`sql/06_testing/`](sql/06_testing/). Each script contains:
- The test query.
- The expected outcome (in a comment).
- The verification query to confirm pass/fail.

**Key tests:**

| Test                             | File                            | What It Checks                                     |
|----------------------------------|---------------------------------|----------------------------------------------------|
| Bronze row counts                | `01_bronze_validation.sql`      | All CSV rows loaded; no silent drops               |
| Silver accepted vs rejected      | `02_silver_validation.sql`      | Expected invalid rows are in REJECTED_RECORDS      |
| Deduplication                    | `02_silver_validation.sql`      | Duplicate reading IDs resolved correctly           |
| Gold aggregation consistency     | `03_gold_validation.sql`        | Gold sums reconcile with Silver counts             |
| Bronze vs Silver reconciliation  | `04_reconciliation_checks.sql`  | Bronze = Silver accepted + CONTROL rejected        |
| Incremental batch scenario       | `05_incremental_batch_test.sql` | New batch of readings processed without duplicates |

> **Note:** Test results documented in script comments are the **expected** outcomes.
> Actual pass/fail status must be verified by running the scripts in Snowflake.
> These scripts have been written and reviewed locally but have not been executed
> in a live Snowflake account as part of this project build.

---

## 16. Example Analytical Questions and Results

These questions are answered by [`sql/07_reports/01_analytical_queries.sql`](sql/07_reports/01_analytical_queries.sql).

| Question                                              | Gold Table Used             |
|-------------------------------------------------------|-----------------------------|
| What are each patient's daily average measurements?   | `GOLD.DAILY_PATIENT_SUMMARY` |
| Which readings triggered example threshold alerts?    | `GOLD.READING_ALERTS`       |
| How do readings change day-over-day?                  | `GOLD.PATIENT_TRENDS`       |
| How many records were accepted vs rejected?           | `CONTROL.REJECTED_RECORDS`  |
| What are the most common quality problems?            | `CONTROL.REJECTED_RECORDS`  |
| How many readings were processed per day?             | `GOLD.DAILY_PATIENT_SUMMARY` |
| Are there patients with invalid device references?   | `CONTROL.REJECTED_RECORDS`  |
| Do Gold aggregates reconcile with Silver?            | Cross-layer count query      |

---

## 17. Known Limitations

1. **Not production-ready.** This is an educational project. No real patient
   data should ever be loaded.
2. **Thresholds are illustrative.** All numeric ranges are chosen for
   demonstration purposes and are not clinical standards.
3. **No real-time streaming.** Data arrives in batch CSV files. True
   real-time streaming (Kafka, Snowpipe) is out of scope for v1.
4. **Single Snowflake account assumed.** Cross-account data sharing is not covered.
5. **No automated tests.** Test scripts must be run manually in Snowsight.
   A CI/CD pipeline for automated testing is a future enhancement.
6. **No role-based access control (RBAC) design.** All scripts run under
   SYSADMIN for simplicity. A production system would use least-privilege roles.
7. **Task execution requires account-level privilege.** The `EXECUTE TASK`
   privilege must be granted by an ACCOUNTADMIN before tasks can run.
8. **Stream staleness.** If no new data is loaded and tasks do not consume the
   stream within 14 days, the stream becomes stale and must be recreated.
9. **SQL scripts not yet executed in a live Snowflake account.** All scripts
   have been written and reviewed for correctness but have not been run in
   a live environment as part of this project build. Execution results shown
   in test scripts are expected outcomes, not confirmed results.
