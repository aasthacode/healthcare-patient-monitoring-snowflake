-- =============================================================================
-- File        : 04_load_silver_readings.sql
-- Layer       : Silver
-- Description : The most complex Silver script. Applies all cleaning rules to
--               BRONZE.RAW_READINGS, routes rejected rows to CONTROL.REJECTED_RECORDS,
--               and merges valid rows into SILVER.CLEAN_READINGS.
--
--               Rules applied (in evaluation order):
--                 Phase 1 — Mandatory field checks
--                 Phase 2 — Type cast failures
--                 Phase 3 — Reference integrity (patient_id, device_id)
--                 Phase 4 — Plausibility range checks (from CONTROL.QUALITY_THRESHOLDS)
--                 Phase 5 — Deduplication (earliest timestamp retained)
--
--               See docs/transformation_rules.md for full rule documentation.
-- Run order   : 9 — run AFTER 03_silver/03_load_silver_devices.sql
--               (reference checks require CLEAN_PATIENTS and CLEAN_DEVICES to exist)
-- Idempotent  : Yes — MERGE on READING_ID; rejection insert has idempotency guard.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

SET SILVER_RDG_RUN_ID = UUID_STRING();
INSERT INTO CONTROL.PIPELINE_RUN_LOG
    (RUN_ID, PIPELINE_NAME, LAYER, STATUS, STARTED_AT, SOURCE_FILE)
VALUES
    ($SILVER_RDG_RUN_ID, 'SILVER_LOAD_READINGS', 'SILVER', 'STARTED',
     CURRENT_TIMESTAMP(), 'patient_readings.csv');


-- =============================================================================
-- STEP 1: Capture current threshold values from the configurable threshold table.
--         Using session variables keeps the rest of the SQL readable and ensures
--         the same threshold is applied consistently within this transaction.
-- =============================================================================
SET HR_MIN  = (SELECT MIN_VALID FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'   AND IS_CURRENT = TRUE);
SET HR_MAX  = (SELECT MAX_VALID FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'   AND IS_CURRENT = TRUE);
SET GL_MIN  = (SELECT MIN_VALID FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE);
SET GL_MAX  = (SELECT MAX_VALID FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE);
SET OS_MIN  = (SELECT MIN_VALID FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'OXYGEN_SAT'   AND IS_CURRENT = TRUE);
SET OS_MAX  = (SELECT MAX_VALID FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'OXYGEN_SAT'   AND IS_CURRENT = TRUE);

-- Confirm thresholds loaded (illustrative values, NOT clinically validated):
SELECT $HR_MIN AS hr_min, $HR_MAX AS hr_max,
       $GL_MIN AS gl_min, $GL_MAX AS gl_max,
       $OS_MIN AS os_min, $OS_MAX AS os_max;


-- =============================================================================
-- STEP 2: Build a staged CTE that evaluates every raw reading against all rules.
--         This CTE is used in BOTH the rejection INSERT and the Silver MERGE.
--
-- Evaluation order (first failure wins — single rejection reason per record):
--   1. RDG-MAND-01: missing reading_id
--   2. RDG-MAND-02: missing patient_id
--   3. RDG-MAND-03: missing device_id
--   4. RDG-MAND-04: timestamp conversion fails
--   5. RDG-MAND-05: heart_rate conversion fails
--   6. RDG-MAND-06: glucose_level conversion fails
--   7. RDG-MAND-07: oxygen_saturation conversion fails
--   8. RDG-REF-01:  patient_id not in CLEAN_PATIENTS
--   9. RDG-REF-02:  device_id not in CLEAN_DEVICES
--  10. RDG-RANGE-01: heart_rate out of plausibility range
--  11. RDG-RANGE-02: glucose_level out of plausibility range
--  12. RDG-RANGE-03: oxygen_saturation out of plausibility range
--  13. DUPLICATE:    reading_id appears more than once (keep earliest)
-- =============================================================================
INSERT INTO CONTROL.REJECTED_RECORDS
    (PIPELINE_RUN_ID, SOURCE_TABLE, READING_ID, PATIENT_ID, DEVICE_ID,
     REJECTION_REASON, RAW_ROW_SNAPSHOT, REJECTED_AT)
WITH

-- Cast the raw strings once so we don't repeat TRY_TO_ calls throughout.
CAST_READINGS AS (
    SELECT
        r.READING_ID,
        r.PATIENT_ID,
        r.DEVICE_ID,
        r.READING_TIMESTAMP                                              AS RAW_TS,
        r.HEART_RATE                                                     AS RAW_HR,
        r.GLUCOSE_LEVEL                                                  AS RAW_GL,
        r.OXYGEN_SATURATION                                              AS RAW_OS,
        TRY_TO_TIMESTAMP(r.READING_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS CAST_TS,
        TRY_TO_NUMBER(r.HEART_RATE)                                      AS CAST_HR,
        TRY_TO_NUMBER(r.GLUCOSE_LEVEL)                                   AS CAST_GL,
        TRY_TO_NUMBER(r.OXYGEN_SATURATION)                               AS CAST_OS,
        r._SOURCE_FILE,
        r._INGESTION_TIMESTAMP
    FROM BRONZE.RAW_READINGS r
),

-- Deduplicate: among records sharing the same reading_id, rank them.
-- Rank 1 = the one we KEEP; ranks 2+ = the ones we REJECT as duplicates.
-- Order: earliest reading_timestamp first; on tie, earliest ingestion_timestamp.
DEDUPED AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.READING_ID
            ORDER BY c.CAST_TS ASC NULLS LAST, c._INGESTION_TIMESTAMP ASC
        ) AS DUP_RANK
    FROM CAST_READINGS c
),

-- Determine the rejection reason for each row using ordered CASE logic.
-- A NULL REJECTION_REASON means the record is valid and should go to Silver.
EVALUATED AS (
    SELECT
        d.*,
        CASE
            -- Phase 1: Mandatory fields
            WHEN d.READING_ID IS NULL OR TRIM(d.READING_ID) = ''
                THEN 'MISSING_READING_ID'
            WHEN d.PATIENT_ID IS NULL OR TRIM(d.PATIENT_ID) = ''
                THEN 'MISSING_PATIENT_ID'
            WHEN d.DEVICE_ID IS NULL OR TRIM(d.DEVICE_ID) = ''
                THEN 'MISSING_DEVICE_ID'
            -- Phase 2: Type cast failures
            WHEN d.CAST_TS IS NULL
                THEN 'INVALID_TIMESTAMP'
            WHEN d.CAST_HR IS NULL
                THEN 'INVALID_HEART_RATE'
            WHEN d.CAST_GL IS NULL
                THEN 'INVALID_GLUCOSE'
            WHEN d.CAST_OS IS NULL
                THEN 'INVALID_OXYGEN_SAT'
            -- Phase 3: Reference integrity
            WHEN NOT EXISTS (
                SELECT 1 FROM SILVER.CLEAN_PATIENTS cp
                WHERE cp.PATIENT_ID = d.PATIENT_ID
            )   THEN 'UNKNOWN_PATIENT_ID'
            WHEN NOT EXISTS (
                SELECT 1 FROM SILVER.CLEAN_DEVICES cd
                WHERE cd.DEVICE_ID = d.DEVICE_ID
            )   THEN 'UNKNOWN_DEVICE_ID'
            -- Phase 4: Plausibility range checks
            WHEN d.CAST_HR < $HR_MIN OR d.CAST_HR > $HR_MAX
                THEN 'HEART_RATE_OUT_OF_RANGE'
            WHEN d.CAST_GL < $GL_MIN OR d.CAST_GL > $GL_MAX
                THEN 'GLUCOSE_OUT_OF_RANGE'
            WHEN d.CAST_OS < $OS_MIN OR d.CAST_OS > $OS_MAX
                THEN 'OXYGEN_SAT_OUT_OF_RANGE'
            -- Phase 5: Deduplication — duplicate rows (DUP_RANK > 1)
            WHEN d.DUP_RANK > 1
                THEN 'DUPLICATE_READING_ID'
            ELSE NULL  -- NULL = valid record; goes to Silver
        END AS REJECTION_REASON
    FROM DEDUPED d
)

-- Insert only the rejected rows (REJECTION_REASON IS NOT NULL).
-- The idempotency guard prevents re-inserting the same rejection on reruns.
SELECT
    $SILVER_RDG_RUN_ID,
    'BRONZE.RAW_READINGS',
    e.READING_ID,
    e.PATIENT_ID,
    e.DEVICE_ID,
    e.REJECTION_REASON,
    'reading_id='  || COALESCE(e.READING_ID,'NULL')
        || '|patient_id='  || COALESCE(e.PATIENT_ID,'NULL')
        || '|device_id='   || COALESCE(e.DEVICE_ID,'NULL')
        || '|ts='          || COALESCE(e.RAW_TS,'NULL')
        || '|hr='          || COALESCE(e.RAW_HR,'NULL')
        || '|gl='          || COALESCE(e.RAW_GL,'NULL')
        || '|os='          || COALESCE(e.RAW_OS,'NULL') AS RAW_ROW_SNAPSHOT,
    CURRENT_TIMESTAMP()
FROM EVALUATED e
WHERE
    e.REJECTION_REASON IS NOT NULL
    -- Idempotency guard: do not re-insert same reading_id + reason combination
    AND NOT EXISTS (
        SELECT 1 FROM CONTROL.REJECTED_RECORDS rr
        WHERE rr.READING_ID        = e.READING_ID
          AND rr.REJECTION_REASON  = e.REJECTION_REASON
    );


-- =============================================================================
-- STEP 3: Merge valid readings into SILVER.CLEAN_READINGS.
--
-- Only rows where REJECTION_REASON IS NULL AND DUP_RANK = 1 are included.
-- The READING_DATE computed column stores just the date portion, which is used
-- extensively in Gold aggregation queries (avoids repeated date truncation).
-- =============================================================================
MERGE INTO SILVER.CLEAN_READINGS AS target
USING (
    WITH CAST_READINGS AS (
        SELECT
            r.READING_ID,
            r.PATIENT_ID,
            r.DEVICE_ID,
            r.READING_TIMESTAMP,
            TRY_TO_TIMESTAMP(r.READING_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS CAST_TS,
            TRY_TO_NUMBER(r.HEART_RATE)                                      AS CAST_HR,
            TRY_TO_NUMBER(r.GLUCOSE_LEVEL)                                   AS CAST_GL,
            TRY_TO_NUMBER(r.OXYGEN_SATURATION)                               AS CAST_OS,
            r._SOURCE_FILE,
            r._INGESTION_TIMESTAMP
        FROM BRONZE.RAW_READINGS r
    ),
    DEDUPED AS (
        SELECT
            c.*,
            ROW_NUMBER() OVER (
                PARTITION BY c.READING_ID
                ORDER BY c.CAST_TS ASC NULLS LAST, c._INGESTION_TIMESTAMP ASC
            ) AS DUP_RANK
        FROM CAST_READINGS c
    )
    SELECT
        d.READING_ID,
        d.PATIENT_ID,
        d.DEVICE_ID,
        d.CAST_TS                                    AS READING_TIMESTAMP,
        d.CAST_TS::DATE                              AS READING_DATE,
        d.CAST_HR                                    AS HEART_RATE,
        d.CAST_GL                                    AS GLUCOSE_LEVEL,
        d.CAST_OS                                    AS OXYGEN_SATURATION,
        d._SOURCE_FILE,
        d._INGESTION_TIMESTAMP
    FROM DEDUPED d
    -- Keep only fully valid rows:
    WHERE
        d.DUP_RANK = 1
        -- Mandatory fields present
        AND d.READING_ID IS NOT NULL AND TRIM(d.READING_ID) != ''
        AND d.PATIENT_ID IS NOT NULL AND TRIM(d.PATIENT_ID) != ''
        AND d.DEVICE_ID  IS NOT NULL AND TRIM(d.DEVICE_ID)  != ''
        -- Type casts succeeded
        AND d.CAST_TS IS NOT NULL
        AND d.CAST_HR IS NOT NULL
        AND d.CAST_GL IS NOT NULL
        AND d.CAST_OS IS NOT NULL
        -- Reference integrity
        AND EXISTS (SELECT 1 FROM SILVER.CLEAN_PATIENTS cp WHERE cp.PATIENT_ID = d.PATIENT_ID)
        AND EXISTS (SELECT 1 FROM SILVER.CLEAN_DEVICES  cd WHERE cd.DEVICE_ID  = d.DEVICE_ID)
        -- Plausibility ranges
        AND d.CAST_HR BETWEEN $HR_MIN AND $HR_MAX
        AND d.CAST_GL BETWEEN $GL_MIN AND $GL_MAX
        AND d.CAST_OS BETWEEN $OS_MIN AND $OS_MAX
) AS source
ON target.READING_ID = source.READING_ID
WHEN MATCHED THEN UPDATE SET
    target.PATIENT_ID          = source.PATIENT_ID,
    target.READING_TIMESTAMP   = source.READING_TIMESTAMP,
    target.READING_DATE        = source.READING_DATE,
    target.HEART_RATE          = source.HEART_RATE,
    target.GLUCOSE_LEVEL       = source.GLUCOSE_LEVEL,
    target.OXYGEN_SATURATION   = source.OXYGEN_SATURATION,
    target.DEVICE_ID           = source.DEVICE_ID,
    target._SOURCE_FILE        = source._SOURCE_FILE,
    target._BRONZE_INGESTED_AT = source._INGESTION_TIMESTAMP,
    target._SILVER_LOADED_AT   = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    READING_ID, PATIENT_ID, READING_TIMESTAMP, READING_DATE,
    HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SATURATION, DEVICE_ID,
    _SOURCE_FILE, _BRONZE_INGESTED_AT, _SILVER_LOADED_AT
) VALUES (
    source.READING_ID, source.PATIENT_ID, source.READING_TIMESTAMP, source.READING_DATE,
    source.HEART_RATE, source.GLUCOSE_LEVEL, source.OXYGEN_SATURATION, source.DEVICE_ID,
    source._SOURCE_FILE, source._INGESTION_TIMESTAMP, CURRENT_TIMESTAMP()
);


-- =============================================================================
-- STEP 4: Update pipeline run log
-- =============================================================================
UPDATE CONTROL.PIPELINE_RUN_LOG
SET
    STATUS        = 'COMPLETED',
    COMPLETED_AT  = CURRENT_TIMESTAMP(),
    ROWS_INPUT    = (SELECT COUNT(*) FROM BRONZE.RAW_READINGS),
    ROWS_ACCEPTED = (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS),
    ROWS_REJECTED = (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS
                     WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS'),
    ROWS_INSERTED = (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS)
WHERE RUN_ID = $SILVER_RDG_RUN_ID;


-- =============================================================================
-- STEP 5: Validation queries
-- =============================================================================

-- Total clean readings:
SELECT COUNT(*) AS clean_readings_count FROM SILVER.CLEAN_READINGS;
-- Expected: approximately 682 (700 total minus ~18 rejected rows)
-- Exact count depends on deduplication of the duplicate reading IDs

-- Rejection summary by reason:
SELECT
    REJECTION_REASON,
    COUNT(*) AS REJECTED_ROW_COUNT
FROM CONTROL.REJECTED_RECORDS
WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS'
GROUP BY REJECTION_REASON
ORDER BY REJECTED_ROW_COUNT DESC;

-- Expected rejections (approximate — see DATA_DICTIONARY.md for exact rows):
-- DUPLICATE_READING_ID       ~5
-- MISSING_PATIENT_ID          1  (R0683)
-- UNKNOWN_PATIENT_ID          1  (R0684)
-- INVALID_HEART_RATE          1  (R0685)
-- INVALID_TIMESTAMP           2  (R0686, R0700)
-- HEART_RATE_OUT_OF_RANGE     2  (R0687: -5, R0689: 220)
-- OXYGEN_SAT_OUT_OF_RANGE     1  (R0688: 115)
-- UNKNOWN_DEVICE_ID           1  (R0690)
-- INVALID_HEART_RATE          1  (R0691: NULL after cast)
-- INVALID_OXYGEN_SAT          1  (R0692: NULL after cast)
-- MISSING_DEVICE_ID           1  (R0693)
-- GLUCOSE_OUT_OF_RANGE        1  (R0694: 2500)

-- Confirm no valid readings were lost — reconciliation check:
SELECT
    (SELECT COUNT(*) FROM BRONZE.RAW_READINGS) AS bronze_total,
    (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS) AS silver_accepted,
    (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS') AS control_rejected,
    (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS)
     + (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS') AS total_accounted_for;
-- bronze_total should equal total_accounted_for

-- Sample valid readings:
SELECT READING_ID, PATIENT_ID, READING_DATE, HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SATURATION, DEVICE_ID
FROM SILVER.CLEAN_READINGS
ORDER BY READING_ID
LIMIT 10;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
