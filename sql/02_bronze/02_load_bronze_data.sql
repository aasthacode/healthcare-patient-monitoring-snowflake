-- =============================================================================
-- File        : 02_load_bronze_data.sql
-- Layer       : Bronze
-- Description : Loads the three CSV source files from the internal stage into
--               the Bronze raw tables using COPY INTO.
--               Also logs load results to CONTROL.PIPELINE_RUN_LOG.
-- Run order   : 5 — run after 02_bronze/01_create_bronze_tables.sql
--               IMPORTANT: Upload the CSV files to @BRONZE.HCM_STAGE first.
--               See sql/01_setup/02_create_file_formats_stages.sql for upload
--               instructions.
-- Idempotent  : Yes — COPY INTO with FORCE=FALSE (default) skips already-loaded
--               files. Safe to rerun without creating duplicates.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- STEP 1: Verify files are present in the stage before loading.
-- Run this manually to confirm the PUT was successful.
-- =============================================================================
LIST @BRONZE.HCM_STAGE;
-- Expected: 3 files — patients.csv, patient_readings.csv, devices.csv
-- (May appear as .gz if auto-compressed by SnowSQL.)


-- =============================================================================
-- STEP 2: Log pipeline start for Bronze load.
-- UUID_STRING() generates a unique run identifier for this execution.
-- We store it in a session variable so it can be referenced in subsequent steps.
-- =============================================================================
SET BRONZE_RUN_ID = UUID_STRING();
SET BRONZE_STARTED_AT = CURRENT_TIMESTAMP();

INSERT INTO CONTROL.PIPELINE_RUN_LOG
    (RUN_ID, PIPELINE_NAME, LAYER, STATUS, STARTED_AT, SOURCE_FILE)
VALUES
    ($BRONZE_RUN_ID, 'BRONZE_LOAD_ALL', 'BRONZE', 'STARTED', $BRONZE_STARTED_AT, 'patients.csv,patient_readings.csv,devices.csv');


-- =============================================================================
-- STEP 3: Load BRONZE.RAW_PATIENTS
--
-- COPY INTO explanation:
--   FROM @BRONZE.HCM_STAGE/patients.csv   — load only this specific file.
--   FILE_FORMAT = ...                      — use the CSV format defined in setup.
--   FORCE = FALSE (default)                — skip if this file was already loaded.
--   ON_ERROR = 'CONTINUE'                 — if an individual row fails, skip it
--                                           and continue loading the rest.
--   PURGE = FALSE (default)               — do not delete the staged file after load.
--   The $1, $2, ... syntax references column positions in the CSV.
--   The METADATA$FILENAME pseudo-column captures the source filename.
-- =============================================================================
COPY INTO BRONZE.RAW_PATIENTS (
    PATIENT_ID,
    AGE,
    GENDER,
    REGISTRATION_DATE,
    CITY,
    _SOURCE_FILE
)
FROM (
    SELECT
        $1,                                   -- patient_id
        $2,                                   -- age
        $3,                                   -- gender
        $4,                                   -- registration_date
        $5,                                   -- city
        METADATA$FILENAME                     -- source file name for traceability
    FROM @BRONZE.HCM_STAGE/patients.csv
    (FILE_FORMAT => 'BRONZE.HCM_CSV_FORMAT')
)
ON_ERROR = 'CONTINUE';
-- _INGESTION_TIMESTAMP is populated automatically by its DEFAULT CURRENT_TIMESTAMP().

-- Quick count after load:
SELECT COUNT(*) AS raw_patients_count FROM BRONZE.RAW_PATIENTS;
-- Expected: 30 rows


-- =============================================================================
-- STEP 4: Load BRONZE.RAW_DEVICES
-- =============================================================================
COPY INTO BRONZE.RAW_DEVICES (
    DEVICE_ID,
    DEVICE_TYPE,
    MANUFACTURER,
    DEPLOYMENT_DATE,
    DEVICE_STATUS,
    _SOURCE_FILE
)
FROM (
    SELECT
        $1,                                   -- device_id
        $2,                                   -- device_type
        $3,                                   -- manufacturer
        $4,                                   -- deployment_date
        $5,                                   -- device_status
        METADATA$FILENAME
    FROM @BRONZE.HCM_STAGE/devices.csv
    (FILE_FORMAT => 'BRONZE.HCM_CSV_FORMAT')
)
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS raw_devices_count FROM BRONZE.RAW_DEVICES;
-- Expected: 15 rows


-- =============================================================================
-- STEP 5: Load BRONZE.RAW_READINGS
--
-- This is the largest and most complex load. The measurement columns are all
-- loaded into VARCHAR columns, so even rows like R0685 (heart_rate = 'abc')
-- load successfully. The Silver layer handles type validation later.
--
-- ON_ERROR = 'CONTINUE' ensures that truly unparseable rows (e.g., wrong number
-- of columns) are skipped rather than aborting the entire load.
-- =============================================================================
COPY INTO BRONZE.RAW_READINGS (
    READING_ID,
    PATIENT_ID,
    READING_TIMESTAMP,
    HEART_RATE,
    GLUCOSE_LEVEL,
    OXYGEN_SATURATION,
    DEVICE_ID,
    _SOURCE_FILE
)
FROM (
    SELECT
        $1,                                   -- reading_id
        $2,                                   -- patient_id
        $3,                                   -- reading_timestamp
        $4,                                   -- heart_rate (may be 'abc', '-5', etc.)
        $5,                                   -- glucose_level
        $6,                                   -- oxygen_saturation
        $7,                                   -- device_id
        METADATA$FILENAME
    FROM @BRONZE.HCM_STAGE/patient_readings.csv
    (FILE_FORMAT => 'BRONZE.HCM_CSV_FORMAT')
)
ON_ERROR = 'CONTINUE';

SELECT COUNT(*) AS raw_readings_count FROM BRONZE.RAW_READINGS;
-- Expected: 700 rows (all rows including intentionally malformed ones)


-- =============================================================================
-- STEP 6: Capture COPY INTO load results for audit purposes.
--
-- COPY_HISTORY shows how many rows were loaded, skipped, and errored.
-- Query this immediately after each COPY INTO while the session history is fresh.
-- =============================================================================

-- Load history for patients:
SELECT
    FILE_NAME,
    STATUS,
    ROWS_LOADED,
    ROWS_PARSED,
    FIRST_ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME   => 'RAW_PATIENTS',
    START_TIME   => DATEADD('minute', -30, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC
LIMIT 5;

-- Load history for devices:
SELECT
    FILE_NAME,
    STATUS,
    ROWS_LOADED,
    ROWS_PARSED,
    FIRST_ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME   => 'RAW_DEVICES',
    START_TIME   => DATEADD('minute', -30, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC
LIMIT 5;

-- Load history for readings:
SELECT
    FILE_NAME,
    STATUS,
    ROWS_LOADED,
    ROWS_PARSED,
    FIRST_ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME   => 'RAW_READINGS',
    START_TIME   => DATEADD('minute', -30, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC
LIMIT 5;


-- =============================================================================
-- STEP 7: Update pipeline run log with completion status.
-- Row counts are set manually here based on the preceding SELECT COUNT(*) results.
-- In a Task-based pipeline, these would be captured dynamically.
-- =============================================================================
UPDATE CONTROL.PIPELINE_RUN_LOG
SET
    STATUS        = 'COMPLETED',
    COMPLETED_AT  = CURRENT_TIMESTAMP(),
    ROWS_INPUT    = (SELECT COUNT(*) FROM BRONZE.RAW_PATIENTS)
                  + (SELECT COUNT(*) FROM BRONZE.RAW_DEVICES)
                  + (SELECT COUNT(*) FROM BRONZE.RAW_READINGS),
    ROWS_INSERTED = (SELECT COUNT(*) FROM BRONZE.RAW_PATIENTS)
                  + (SELECT COUNT(*) FROM BRONZE.RAW_DEVICES)
                  + (SELECT COUNT(*) FROM BRONZE.RAW_READINGS)
WHERE RUN_ID = $BRONZE_RUN_ID;


-- =============================================================================
-- STEP 8: Final Bronze validation summary.
-- =============================================================================
SELECT 'RAW_PATIENTS'  AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM BRONZE.RAW_PATIENTS
UNION ALL
SELECT 'RAW_DEVICES'   AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM BRONZE.RAW_DEVICES
UNION ALL
SELECT 'RAW_READINGS'  AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM BRONZE.RAW_READINGS
ORDER BY TABLE_NAME;

-- Expected results:
-- RAW_DEVICES    15
-- RAW_PATIENTS   30
-- RAW_READINGS   700

-- Spot-check a sample of malformed rows to confirm they loaded as VARCHAR:
SELECT READING_ID, PATIENT_ID, HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SATURATION, DEVICE_ID
FROM BRONZE.RAW_READINGS
WHERE READING_ID IN ('R0683','R0684','R0685','R0686','R0687','R0688','R0689','R0690',
                     'R0691','R0692','R0693','R0694','R0695','R0696','R0700')
ORDER BY READING_ID;

-- These rows should all be present as raw strings, not cast to numbers yet.


-- =============================================================================
-- HOW TO RELOAD A TEST FILE (FOR DEVELOPMENT PURPOSES)
--
-- If you need to test the Bronze load again from scratch during development:
--
-- 1. Truncate the Bronze table (WARNING: deletes all data):
--    TRUNCATE TABLE BRONZE.RAW_READINGS;
--
-- 2. Re-run COPY INTO with FORCE = TRUE to bypass the load-history check:
--    COPY INTO BRONZE.RAW_READINGS (...)
--    FROM (SELECT ... FROM @BRONZE.HCM_STAGE/patient_readings.csv (...))
--    FORCE = TRUE
--    ON_ERROR = 'CONTINUE';
--
-- Do NOT use FORCE=TRUE in production. It will create duplicate rows if the
-- Bronze table was not truncated first.
-- =============================================================================

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
