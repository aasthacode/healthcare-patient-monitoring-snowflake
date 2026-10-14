# Transformation Rules — Silver Layer Cleaning

> This document defines every cleaning and validation rule applied when
> promoting data from the Bronze layer to the Silver layer. Each rule includes
> the rationale, the SQL approach, and the expected outcome for passing and
> failing records.

---

## Guiding Principles

1. **Preserve, don't delete.** Raw Bronze records are never modified. Records
   that fail validation are written to `CONTROL.REJECTED_RECORDS` with a
   documented reason rather than silently discarded.
2. **Safe casting.** All type conversions use Snowflake's `TRY_TO_*` family of
   functions, which return NULL instead of erroring on bad input.
3. **Single rejection reason per record.** When a record fails multiple checks,
   the first triggered rule in the ordered evaluation sequence is recorded.
4. **Deterministic deduplication.** The rule for choosing which duplicate to
   keep is fully documented and consistently applied.
5. **Configurable thresholds.** Plausibility ranges are read from
   `CONTROL.QUALITY_THRESHOLDS` rather than hard-coded.

---

## Rules for SILVER.CLEAN_PATIENTS

The `patients.csv` source file is expected to be clean. The following
defensive checks are still applied.

| Rule ID | Column             | Rule                                                    | Action on failure           | Reason                                      |
|---------|--------------------|---------------------------------------------------------|-----------------------------|---------------------------------------------|
| PAT-01  | `patient_id`       | Must not be NULL or empty.                              | Reject to CONTROL           | Cannot create a patient record without an ID. |
| PAT-02  | `patient_id`       | Must match pattern `P[0-9]{3}`.                         | Reject to CONTROL           | Enforces expected ID format.                |
| PAT-03  | `age`              | Must convert to INTEGER. Must be between 0 and 120.     | Reject to CONTROL           | Ages outside this range suggest data entry errors. |
| PAT-04  | `gender`           | Must not be NULL. Standardise to title case.            | NULL set to `Unknown`       | Preserves the record; flags missing gender. |
| PAT-05  | `registration_date`| Must convert to DATE using `TRY_TO_DATE`.               | Reject to CONTROL           | A patient with no valid registration date cannot be traceably linked to readings. |

**Standardisation:** `gender` is stored as `INITCAP(TRIM(gender))`.

---

## Rules for SILVER.CLEAN_DEVICES

| Rule ID | Column           | Rule                                                        | Action on failure | Reason                                                      |
|---------|------------------|-------------------------------------------------------------|-------------------|-------------------------------------------------------------|
| DEV-01  | `device_id`      | Must not be NULL or empty.                                  | Reject to CONTROL | Cannot process device without ID.                           |
| DEV-02  | `device_type`    | Must not be NULL. Standardise to title case.                | Reject to CONTROL | Needed for alert classification.                            |
| DEV-03  | `device_status`  | Must be one of `Active`, `Maintenance`, `Retired` (case-insensitive). If unrecognised, set to `Unknown`. | Set to `Unknown` | Preserves the record but flags the anomaly.              |
| DEV-04  | `deployment_date`| Must convert to DATE using `TRY_TO_DATE`.                   | Reject to CONTROL | Cannot validate device timeline without a date.             |

**Standardisation:** `device_status` is stored as `INITCAP(TRIM(device_status))`.

---

## Rules for SILVER.CLEAN_READINGS

Readings undergo the most thorough validation because they contain the
measurement data and the most intentional quality problems.

### Phase 1 — Type Casting (Safe Conversions)

| Rule ID | Column               | Conversion                           | Action on NULL result     |
|---------|----------------------|--------------------------------------|---------------------------|
| RDG-01  | `reading_timestamp`  | `TRY_TO_TIMESTAMP(col, 'YYYY-MM-DD HH24:MI:SS')` | Reject: RDG-NULL-TS       |
| RDG-02  | `heart_rate`         | `TRY_TO_NUMBER(col, 10, 2)`          | Reject: RDG-NULL-HR       |
| RDG-03  | `glucose_level`      | `TRY_TO_NUMBER(col, 10, 2)`          | Reject: RDG-NULL-GL       |
| RDG-04  | `oxygen_saturation`  | `TRY_TO_NUMBER(col, 10, 2)`          | Reject: RDG-NULL-OS       |

### Phase 2 — Mandatory Field Checks

| Rule ID     | Column              | Rule                             | Rejection Reason Code   |
|-------------|---------------------|----------------------------------|-------------------------|
| RDG-MAND-01 | `reading_id`        | Must not be NULL or empty.       | `MISSING_READING_ID`    |
| RDG-MAND-02 | `patient_id`        | Must not be NULL or empty.       | `MISSING_PATIENT_ID`    |
| RDG-MAND-03 | `device_id`         | Must not be NULL or empty.       | `MISSING_DEVICE_ID`     |
| RDG-MAND-04 | `reading_timestamp` | Cast result must not be NULL.    | `INVALID_TIMESTAMP`     |
| RDG-MAND-05 | `heart_rate`        | Cast result must not be NULL.    | `INVALID_HEART_RATE`    |
| RDG-MAND-06 | `glucose_level`     | Cast result must not be NULL.    | `INVALID_GLUCOSE`       |
| RDG-MAND-07 | `oxygen_saturation` | Cast result must not be NULL.    | `INVALID_OXYGEN_SAT`    |

### Phase 3 — Reference Integrity Checks

| Rule ID     | Column       | Rule                                                     | Rejection Reason Code    |
|-------------|--------------|----------------------------------------------------------|--------------------------|
| RDG-REF-01  | `patient_id` | Must exist in `SILVER.CLEAN_PATIENTS.patient_id`.        | `UNKNOWN_PATIENT_ID`     |
| RDG-REF-02  | `device_id`  | Must exist in `SILVER.CLEAN_DEVICES.device_id`.          | `UNKNOWN_DEVICE_ID`      |

**Why Silver for reference checks?** Patients and devices are cleaned first.
Readings reference the already-validated dimension tables, so we check against
Silver rather than Bronze to avoid false positives from not-yet-cleaned records.

### Phase 4 — Plausibility Range Checks

Thresholds are read from `CONTROL.QUALITY_THRESHOLDS`. The table contains
`metric_name`, `min_valid`, `max_valid`, `alert_min`, `alert_max`.

| Rule ID      | Metric               | Plausibility Check                              | Rejection Reason Code       |
|--------------|----------------------|-------------------------------------------------|-----------------------------|
| RDG-RANGE-01 | `heart_rate`         | Must be between `min_valid` and `max_valid`.    | `HEART_RATE_OUT_OF_RANGE`   |
| RDG-RANGE-02 | `glucose_level`      | Must be between `min_valid` and `max_valid`.    | `GLUCOSE_OUT_OF_RANGE`      |
| RDG-RANGE-03 | `oxygen_saturation`  | Must be between `min_valid` and `max_valid`.    | `OXYGEN_SAT_OUT_OF_RANGE`   |

> These are illustrative plausibility checks, not clinical diagnostic criteria.

### Phase 5 — Deduplication

A duplicate is any record sharing a `reading_id` with another record already
in `CLEAN_READINGS`, or appearing more than once in the same load batch.

**Retention rule:** Among records sharing the same `reading_id`, retain the
one with the **earliest `reading_timestamp`**. If timestamps are equal, retain
the one with the **earliest `_ingestion_timestamp`** (i.e., the one loaded
first). All other duplicates are rejected.

SQL approach:
```sql
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY reading_id
    ORDER BY reading_timestamp ASC, _ingestion_timestamp ASC
) = 1
```

Rejected duplicates receive reason code `DUPLICATE_READING_ID`.

---

## Rejection Record Structure

Every rejected record is written to `CONTROL.REJECTED_RECORDS` with:

| Column              | Description                                                    |
|---------------------|----------------------------------------------------------------|
| `rejection_id`      | Auto-incrementing surrogate key.                               |
| `source_table`      | Bronze table the record came from.                             |
| `reading_id`        | The original `reading_id` (may be NULL if missing).            |
| `patient_id`        | The original `patient_id` (may be NULL if missing).            |
| `rejection_reason`  | The rule reason code from the tables above.                    |
| `raw_row_snapshot`  | A VARCHAR snapshot of the key column values at rejection time. |
| `rejected_at`       | Timestamp when the rejection was recorded.                     |
| `pipeline_run_id`   | Foreign key to `CONTROL.PIPELINE_RUN_LOG`.                     |

---

## Rule Evaluation Order

Rules are evaluated in this order. The first failure stops further evaluation
for that record (single-reason rejection):

1. Mandatory field checks (Phase 2)
2. Type cast failures (Phase 1, evaluated together)
3. Reference integrity checks (Phase 3)
4. Plausibility range checks (Phase 4)
5. Deduplication (Phase 5)

---

## Silver to Gold Promotion

Only records in `SILVER.CLEAN_READINGS` with matching rows in
`SILVER.CLEAN_PATIENTS` and `SILVER.CLEAN_DEVICES` are included in Gold
aggregations. This is enforced via INNER JOIN in Gold transformation SQL.
