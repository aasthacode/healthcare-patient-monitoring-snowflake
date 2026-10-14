-- =============================================================================
-- File        : 02_load_silver_patients.sql
-- Layer       : Silver
-- Description : Cleans BRONZE.RAW_PATIENTS and loads valid records into
--               SILVER.CLEAN_PATIENTS. Rejected records go to CONTROL.REJECTED_RECORDS.
--               Uses MERGE to make the script safely re-runnable.
-- Run order   : 7 — run after 03_silver/01_create_silver_tables.sql
-- Idempotent  : Yes — MERGE matches on PATIENT_ID; re-runs update rather than
--               insert duplicates.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- Log pipeline start
SET SILVER_PAT_RUN_ID = UUID_STRING();
INSERT INTO CONTROL.PIPELINE_RUN_LOG
    (RUN_ID, PIPELINE_NAME, LAYER, STATUS, STARTED_AT, SOURCE_FILE)
VALUES
    ($SILVER_PAT_RUN_ID, 'SILVER_LOAD_PATIENTS', 'SILVER', 'STARTED',
     CURRENT_TIMESTAMP(), 'patients.csv');


-- =============================================================================
-- STEP 1: Apply cleaning rules to RAW_PATIENTS.
--
-- Rules applied (see docs/transformation_rules.md for full catalogue):
--   PAT-01 : patient_id must not be NULL or empty.
--   PAT-02 : patient_id must match pattern P[0-9]{3}.
--   PAT-03 : age must convert to INTEGER and be in range 0–120.
--   PAT-04 : gender NULL → 'Unknown' (soft rule; record still accepted).
--   PAT-05 : registration_date must convert to DATE successfully.
--
-- TRY_TO_NUMBER and TRY_TO_DATE return NULL on failure rather than erroring.
-- We check for NULL to detect conversion failures.
-- =============================================================================
INSERT INTO CONTROL.REJECTED_RECORDS
    (PIPELINE_RUN_ID, SOURCE_TABLE, READING_ID, PATIENT_ID, REJECTION_REASON,
     RAW_ROW_SNAPSHOT, REJECTED_AT)
SELECT
    $SILVER_PAT_RUN_ID,
    'BRONZE.RAW_PATIENTS',
    NULL,                                           -- no reading_id in patients table
    p.PATIENT_ID,
    CASE
        -- PAT-01: missing patient_id
        WHEN p.PATIENT_ID IS NULL OR TRIM(p.PATIENT_ID) = ''
            THEN 'MISSING_PATIENT_ID'
        -- PAT-02: patient_id format does not match P + 3 digits
        WHEN NOT REGEXP_LIKE(p.PATIENT_ID, '^P[0-9]{3}$')
            THEN 'INVALID_PATIENT_ID_FORMAT'
        -- PAT-03: age is not a valid number
        WHEN TRY_TO_NUMBER(p.AGE) IS NULL
            THEN 'INVALID_AGE_FORMAT'
        -- PAT-03: age is outside 0–120
        WHEN TRY_TO_NUMBER(p.AGE) < 0 OR TRY_TO_NUMBER(p.AGE) > 120
            THEN 'AGE_OUT_OF_RANGE'
        -- PAT-05: registration_date cannot be parsed
        WHEN TRY_TO_DATE(p.REGISTRATION_DATE, 'YYYY-MM-DD') IS NULL
            THEN 'INVALID_REGISTRATION_DATE'
    END                                             AS REJECTION_REASON,
    'patient_id=' || COALESCE(p.PATIENT_ID,'NULL')
        || '|age=' || COALESCE(p.AGE,'NULL')
        || '|registration_date=' || COALESCE(p.REGISTRATION_DATE,'NULL')
                                                    AS RAW_ROW_SNAPSHOT,
    CURRENT_TIMESTAMP()
FROM BRONZE.RAW_PATIENTS p
WHERE
    -- Only insert if this combination was not already rejected in this run
    (
        p.PATIENT_ID IS NULL OR TRIM(p.PATIENT_ID) = ''
        OR NOT REGEXP_LIKE(p.PATIENT_ID, '^P[0-9]{3}$')
        OR TRY_TO_NUMBER(p.AGE) IS NULL
        OR TRY_TO_NUMBER(p.AGE) < 0 OR TRY_TO_NUMBER(p.AGE) > 120
        OR TRY_TO_DATE(p.REGISTRATION_DATE, 'YYYY-MM-DD') IS NULL
    )
    -- Idempotency guard: skip if already recorded for the same patient/reason
    AND NOT EXISTS (
        SELECT 1 FROM CONTROL.REJECTED_RECORDS r
        WHERE  r.PATIENT_ID = p.PATIENT_ID
          AND  r.REJECTION_REASON = CASE
                  WHEN p.PATIENT_ID IS NULL OR TRIM(p.PATIENT_ID) = ''
                      THEN 'MISSING_PATIENT_ID'
                  WHEN NOT REGEXP_LIKE(p.PATIENT_ID, '^P[0-9]{3}$')
                      THEN 'INVALID_PATIENT_ID_FORMAT'
                  WHEN TRY_TO_NUMBER(p.AGE) IS NULL
                      THEN 'INVALID_AGE_FORMAT'
                  WHEN TRY_TO_NUMBER(p.AGE) < 0 OR TRY_TO_NUMBER(p.AGE) > 120
                      THEN 'AGE_OUT_OF_RANGE'
                  WHEN TRY_TO_DATE(p.REGISTRATION_DATE, 'YYYY-MM-DD') IS NULL
                      THEN 'INVALID_REGISTRATION_DATE'
               END
    );


-- =============================================================================
-- STEP 2: MERGE valid records into SILVER.CLEAN_PATIENTS.
--
-- MERGE (rather than INSERT) ensures idempotency:
--   - On first run: inserts new rows.
--   - On subsequent runs: updates existing rows if the source data changed.
--   - Never creates duplicates.
--
-- Only rows that pass ALL rules are included in the WHEN NOT MATCHED / WHEN
-- MATCHED branches. The WHERE clause filters out any row that would fail a check.
-- =============================================================================
MERGE INTO SILVER.CLEAN_PATIENTS AS target
USING (
    SELECT
        p.PATIENT_ID,
        TRY_TO_NUMBER(p.AGE)::NUMBER(3,0)               AS AGE,
        -- PAT-04: if gender is NULL, substitute 'Unknown' (soft rule)
        INITCAP(TRIM(COALESCE(p.GENDER, 'Unknown')))    AS GENDER,
        TRY_TO_DATE(p.REGISTRATION_DATE, 'YYYY-MM-DD')  AS REGISTRATION_DATE,
        TRIM(p.CITY)                                     AS CITY,
        p._SOURCE_FILE,
        p._INGESTION_TIMESTAMP
    FROM BRONZE.RAW_PATIENTS p
    WHERE
        -- Must have a valid patient_id
        p.PATIENT_ID IS NOT NULL
        AND TRIM(p.PATIENT_ID) != ''
        AND REGEXP_LIKE(p.PATIENT_ID, '^P[0-9]{3}$')
        -- Age must be a valid number in range
        AND TRY_TO_NUMBER(p.AGE) IS NOT NULL
        AND TRY_TO_NUMBER(p.AGE) BETWEEN 0 AND 120
        -- Registration date must parse
        AND TRY_TO_DATE(p.REGISTRATION_DATE, 'YYYY-MM-DD') IS NOT NULL
) AS source
ON target.PATIENT_ID = source.PATIENT_ID
-- If row already exists in Silver, update it (handles reloads or corrections).
WHEN MATCHED THEN UPDATE SET
    target.AGE               = source.AGE,
    target.GENDER            = source.GENDER,
    target.REGISTRATION_DATE = source.REGISTRATION_DATE,
    target.CITY              = source.CITY,
    target._SOURCE_FILE      = source._SOURCE_FILE,
    target._BRONZE_INGESTED_AT = source._INGESTION_TIMESTAMP,
    target._SILVER_LOADED_AT = CURRENT_TIMESTAMP()
-- If row is new, insert it.
WHEN NOT MATCHED THEN INSERT (
    PATIENT_ID, AGE, GENDER, REGISTRATION_DATE, CITY,
    _SOURCE_FILE, _BRONZE_INGESTED_AT, _SILVER_LOADED_AT
) VALUES (
    source.PATIENT_ID, source.AGE, source.GENDER, source.REGISTRATION_DATE, source.CITY,
    source._SOURCE_FILE, source._INGESTION_TIMESTAMP, CURRENT_TIMESTAMP()
);


-- =============================================================================
-- STEP 3: Update pipeline run log with row counts.
-- =============================================================================
UPDATE CONTROL.PIPELINE_RUN_LOG
SET
    STATUS        = 'COMPLETED',
    COMPLETED_AT  = CURRENT_TIMESTAMP(),
    ROWS_INPUT    = (SELECT COUNT(*) FROM BRONZE.RAW_PATIENTS),
    ROWS_ACCEPTED = (SELECT COUNT(*) FROM SILVER.CLEAN_PATIENTS),
    ROWS_REJECTED = (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS
                     WHERE PIPELINE_RUN_ID = $SILVER_PAT_RUN_ID),
    ROWS_INSERTED = (SELECT COUNT(*) FROM SILVER.CLEAN_PATIENTS)
WHERE RUN_ID = $SILVER_PAT_RUN_ID;


-- =============================================================================
-- STEP 4: Validation
-- =============================================================================
SELECT COUNT(*) AS clean_patients_count FROM SILVER.CLEAN_PATIENTS;
-- Expected: 30 (all patient rows pass validation — patients.csv is clean)

SELECT COUNT(*) AS rejected_patient_count
FROM CONTROL.REJECTED_RECORDS
WHERE SOURCE_TABLE = 'BRONZE.RAW_PATIENTS';
-- Expected: 0 (patients.csv has no intentional quality problems)

-- Sample the cleaned data:
SELECT PATIENT_ID, AGE, GENDER, REGISTRATION_DATE, CITY
FROM SILVER.CLEAN_PATIENTS
ORDER BY PATIENT_ID
LIMIT 10;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
