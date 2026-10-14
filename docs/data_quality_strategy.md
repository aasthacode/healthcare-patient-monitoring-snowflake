# Data Quality Strategy

> This document describes the overall approach to data quality in the
> Healthcare Patient Monitoring pipeline — what is checked, how failures are
> handled, how quality is monitored over time, and how the system prevents
> double-counting or duplicate logging across repeated pipeline runs.

---

## Philosophy

**Quality is enforced, not assumed.** Every record that enters Silver has
passed an explicit set of checks. Records that fail are not deleted — they are
preserved with a documented reason in `CONTROL.REJECTED_RECORDS`.

**Transparency over silence.** If a record is removed from the analytical
path, there is always an audit trail explaining why.

**Repeatability.** Pipeline scripts are safe to run multiple times. Duplicate
prevention is built into every layer.

---

## Quality Dimensions Addressed

| Dimension      | Description                                               | Where Enforced              |
|----------------|-----------------------------------------------------------|-----------------------------|
| Completeness   | Required fields must be present and non-null.             | Silver mandatory checks     |
| Validity       | Values must meet type and format expectations.            | Silver type casting         |
| Consistency    | Foreign keys must reference known dimension records.      | Silver reference checks     |
| Plausibility   | Numeric values must fall within configured ranges.        | Silver range checks         |
| Uniqueness     | Duplicate primary keys are detected and resolved.         | Silver deduplication        |
| Timeliness     | Timestamps must be parseable and logically valid.         | Silver timestamp validation |

---

## Control Tables

### CONTROL.REJECTED_RECORDS

Holds every record that failed a Silver cleaning rule.

- Populated by Silver transformation scripts via `INSERT`.
- Each row contains the rejection reason code, a snapshot of key fields, the
  source Bronze table, and the pipeline run ID.
- Never modified once written (append-only).
- **Duplicate prevention:** Before inserting, the pipeline checks whether a
  rejection entry for the same `reading_id` and `pipeline_run_id` already
  exists. This prevents double-counting on reruns.

### CONTROL.PIPELINE_RUN_LOG

One row per pipeline execution.

| Column            | Description                                              |
|-------------------|----------------------------------------------------------|
| `run_id`          | UUID generated at runtime using `UUID_STRING()`.         |
| `pipeline_name`   | Logical name of the pipeline step (e.g., `SILVER_LOAD`). |
| `layer`           | `BRONZE`, `SILVER`, `GOLD`, or `CONTROL`.               |
| `status`          | `STARTED`, `COMPLETED`, `FAILED`.                        |
| `started_at`      | `CURRENT_TIMESTAMP` when the run began.                  |
| `completed_at`    | `CURRENT_TIMESTAMP` when the run finished.               |
| `source_file`     | Source filename where relevant.                          |
| `rows_input`      | Number of rows read from source.                         |
| `rows_accepted`   | Number of rows that passed all checks.                   |
| `rows_rejected`   | Number of rows that failed at least one check.           |
| `rows_inserted`   | Number of rows inserted into the target table.           |
| `error_message`   | NULL on success; error text on failure.                  |

### CONTROL.DATA_QUALITY_LOG

One row per individual quality check result per run.

| Column        | Description                                          |
|---------------|------------------------------------------------------|
| `log_id`      | Auto-incrementing surrogate key.                     |
| `run_id`      | Foreign key to `PIPELINE_RUN_LOG`.                   |
| `check_name`  | Short name of the check (e.g., `DUPLICATE_IDS`).     |
| `layer`       | Layer where the check ran.                           |
| `table_name`  | Fully qualified table name checked.                  |
| `check_result`| `PASSED` or `FAILED`.                               |
| `row_count`   | Number of rows that triggered this check.            |
| `checked_at`  | Timestamp of check execution.                        |
| `notes`       | Additional context.                                  |

### CONTROL.QUALITY_THRESHOLDS

Configurable plausibility thresholds. Silver and Gold SQL read from this table
rather than using hard-coded values.

| Column        | Description                                          |
|---------------|------------------------------------------------------|
| `metric_name` | One of `HEART_RATE`, `GLUCOSE_LEVEL`, `OXYGEN_SAT`. |
| `min_valid`   | Minimum acceptable value. Records below are rejected.|
| `max_valid`   | Maximum acceptable value. Records above are rejected.|
| `alert_min`   | Threshold below which a Gold alert is generated.     |
| `alert_max`   | Threshold above which a Gold alert is generated.     |
| `effective_from`| Date this threshold version became active.         |
| `is_current`  | `TRUE` for the active threshold row.                 |

---

## Reconciliation Checks

After each pipeline run, the following reconciliation queries should be run to
confirm counts are consistent. These are in `sql/06_testing/`.

1. **Bronze total vs Silver accepted + rejected:**
   ```
   Bronze rows loaded == Silver accepted rows + CONTROL rejected rows
   ```
2. **Gold daily summary vs Silver readings:**
   ```
   SUM(total_readings) in GOLD.DAILY_PATIENT_SUMMARY
   == COUNT(*) in SILVER.CLEAN_READINGS (for same date range)
   ```
3. **Duplicate rejection counts:**
   ```
   Rejected records with reason DUPLICATE_READING_ID
   == COUNT of duplicate reading IDs in Bronze minus 1 per group
   ```
4. **Unknown reference counts:**
   ```
   Rejected records with UNKNOWN_PATIENT_ID or UNKNOWN_DEVICE_ID
   == COUNT of readings in Bronze referencing IDs not in CLEAN_PATIENTS or CLEAN_DEVICES
   ```

---

## Preventing Double-Counting on Reruns

A key challenge is ensuring that running the Silver transformation twice does
not create duplicate rejected records or duplicate Silver rows.

**Strategy:**
- `SILVER.CLEAN_READINGS` uses a `MERGE` statement keyed on `reading_id`.
  Re-running updates existing records rather than inserting duplicates.
- `CONTROL.REJECTED_RECORDS` inserts are filtered with:
  ```sql
  WHERE NOT EXISTS (
      SELECT 1 FROM CONTROL.REJECTED_RECORDS r
      WHERE r.reading_id = source.reading_id
        AND r.rejection_reason = source.rejection_reason
  )
  ```
  This ensures the same record isn't rejected twice for the same reason.
- `CONTROL.PIPELINE_RUN_LOG` generates a new `run_id` for every execution,
  so each run is independently logged regardless of reruns.

---

## What Is Explicitly Out of Scope

- Real-time streaming data quality checks (no Kafka or Snowpipe in v1).
- Automated alerting or notification (no email/Slack).
- Statistical anomaly detection (no ML models).
- Clinical validation (all thresholds are illustrative examples only).
