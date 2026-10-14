-- =============================================================================
-- File        : 05_incremental_batch_test.sql
-- Layer       : Testing — Incremental batch scenario
-- Description : Simulates loading a second batch of readings after the initial
--               pipeline run. Tests that:
--                 1. New records are processed into Silver without duplicating
--                    records from the first batch.
--                 2. The stream captures the new rows.
--                 3. Gold tables are updated to reflect the new readings.
--                 4. Rejected records from batch 2 are correctly isolated.
--
-- HOW TO RUN:
--   Step 1: Complete the full pipeline (Bronze → Silver → Gold).
--   Step 2: Upload batch_2_readings.csv to @BRONZE.HCM_STAGE.
--           (This file is defined at the bottom of this script — create it first.)
--   Step 3: Run this script top to bottom.
--   Step 4: Check the validation queries at the end.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- STEP 0: Record Silver and Gold row counts BEFORE the incremental load.
--         We will compare these to counts after the load.
-- =============================================================================
SET BEFORE_SILVER_COUNT = (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS);
SET BEFORE_GOLD_SUMMARY_COUNT = (SELECT COUNT(*) FROM GOLD.DAILY_PATIENT_SUMMARY);
SET BEFORE_REJECTION_COUNT = (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS
                               WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS');

SELECT $BEFORE_SILVER_COUNT AS before_silver,
       $BEFORE_GOLD_SUMMARY_COUNT AS before_gold_summary,
       $BEFORE_REJECTION_COUNT AS before_rejections;


-- =============================================================================
-- STEP 1: Define the second batch CSV content.
--
-- Create this file locally as: data/patient_readings_batch2.csv
-- Then upload it: PUT file:///path/to/data/patient_readings_batch2.csv
--                      @BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
--
-- Batch 2 contents (copy below as the CSV file):
-- -----------------------------------------------
-- reading_id,patient_id,reading_timestamp,heart_rate,glucose_level,oxygen_saturation,device_id
-- R0800,P001,2024-02-01 08:00:00,74,98.0,98,D001
-- R0801,P002,2024-02-01 09:00:00,88,150.0,94,D002
-- R0802,P003,2024-02-01 07:30:00,66,87.0,99,D003
-- R0803,P004,2024-02-01 08:30:00,93,181.0,93,D004
-- R0804,P005,2024-02-01 10:00:00,80,115.0,96,D011
-- R0805,P001,2024-02-02 08:00:00,75,100.0,97,D001
-- R0806,P002,2024-02-02 09:00:00,89,153.0,93,D002
-- R0807,P003,2024-02-02 07:30:00,67,88.0,98,D003
-- R0808,P004,2024-02-02 08:30:00,94,184.0,92,D004
-- R0809,P005,2024-02-02 10:00:00,81,117.0,95,D011
-- R0001,P001,2024-01-10 08:00:00,72,95.2,98,D001   <-- DUPLICATE of existing R0001
-- R0810,P999,2024-02-03 08:00:00,78,105.0,96,D001  <-- Unknown patient P999
-- -----------------------------------------------
-- =============================================================================


-- =============================================================================
-- STEP 2: Load batch 2 into Bronze using COPY INTO.
-- This will only work if patient_readings_batch2.csv has been uploaded to the stage.
-- =============================================================================
COPY INTO BRONZE.RAW_READINGS (
    READING_ID, PATIENT_ID, READING_TIMESTAMP, HEART_RATE,
    GLUCOSE_LEVEL, OXYGEN_SATURATION, DEVICE_ID, _SOURCE_FILE
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, METADATA$FILENAME
    FROM @BRONZE.HCM_STAGE/patient_readings_batch2.csv
    (FILE_FORMAT => 'BRONZE.HCM_CSV_FORMAT')
)
ON_ERROR = 'CONTINUE';


-- =============================================================================
-- STEP 3: Verify batch 2 rows landed in Bronze.
-- Expected: Bronze row count increased by 12 (10 valid + 1 duplicate + 1 bad ref)
-- =============================================================================
SELECT COUNT(*) AS bronze_after FROM BRONZE.RAW_READINGS;
-- Expected: 712 (700 from batch 1 + 12 from batch 2)


-- =============================================================================
-- STEP 4: Run Silver cleaning on the new batch rows.
--
-- Option A — Manual (using the full Silver load script with MERGE):
--   Re-run sql/03_silver/04_load_silver_readings.sql
--   The MERGE handles idempotency: existing reading_ids are updated, new ones inserted.
--
-- Option B — Automated (if Tasks are active):
--   The stream will have captured the new Bronze rows.
--   Wait for SILVER_INCREMENTAL_TASK to fire (up to 15 minutes), then check Silver.
--
-- For this test, we use Option A (manual re-run):
-- =============================================================================

-- Re-run the full Silver readings load:
-- (Copy the content of sql/03_silver/04_load_silver_readings.sql here, or run it separately.)
-- The MERGE will insert the 10 new valid rows and skip already-existing R0001.


-- =============================================================================
-- STEP 5: Verify incremental processing results.
-- =============================================================================

-- TEST INC-01: Silver count increased by 10 (not 12 — duplicate and bad ref excluded)
SELECT
    'INC-01' AS TEST_ID,
    'Silver grew by 10 new valid rows' AS TEST_NAME,
    (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS) AS after_silver,
    $BEFORE_SILVER_COUNT AS before_silver,
    (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS) - $BEFORE_SILVER_COUNT AS delta,
    CASE WHEN (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS) - $BEFORE_SILVER_COUNT = 10
         THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT;
-- Expected delta: 10

-- TEST INC-02: R0001 (duplicate) was NOT added to Silver again
SELECT
    'INC-02' AS TEST_ID,
    'Duplicate R0001 not double-loaded to Silver' AS TEST_NAME,
    COUNT(*) AS R0001_COUNT_IN_SILVER,
    CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS WHERE READING_ID = 'R0001';

-- TEST INC-03: R0001 duplicate from batch 2 is recorded in REJECTED_RECORDS
SELECT
    'INC-03' AS TEST_ID,
    'Batch 2 duplicate R0001 recorded as rejected' AS TEST_NAME,
    COUNT(*) AS REJECTION_COUNT,
    CASE WHEN COUNT(*) >= 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0001' AND REJECTION_REASON = 'DUPLICATE_READING_ID';

-- TEST INC-04: R0810 (unknown patient P999) was rejected
SELECT
    'INC-04' AS TEST_ID,
    'R0810 rejected: UNKNOWN_PATIENT_ID' AS TEST_NAME,
    COUNT(*) AS FOUND,
    CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0810' AND REJECTION_REASON = 'UNKNOWN_PATIENT_ID';

-- TEST INC-05: Rejection count increased (new rejections from batch 2)
SELECT
    'INC-05' AS TEST_ID,
    'New rejections recorded from batch 2' AS TEST_NAME,
    (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS') AS after_rejections,
    $BEFORE_REJECTION_COUNT AS before_rejections,
    (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS') - $BEFORE_REJECTION_COUNT AS new_rejections,
    CASE WHEN ((SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS')
               - $BEFORE_REJECTION_COUNT) >= 2
         THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT;
-- Expected: at least 2 new rejections (R0001 dup + R0810 unknown patient)


-- =============================================================================
-- STEP 6: Re-run Gold scripts and verify Gold updated.
-- Run sql/04_gold/02_load_gold_daily_summary.sql (and 04_load_gold_patient_trends.sql)
-- =============================================================================

-- TEST INC-06: Gold summary grew for 2024-02-01 and 2024-02-02 (new dates)
SELECT
    'INC-06' AS TEST_ID,
    'Gold summary has rows for new batch 2 dates' AS TEST_NAME,
    COUNT(*) AS NEW_DATE_ROWS,
    CASE WHEN COUNT(*) >= 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM GOLD.DAILY_PATIENT_SUMMARY
WHERE READING_DATE IN ('2024-02-01', '2024-02-02');

-- TEST INC-07: Stream has been consumed (if using Task automation)
SELECT
    'INC-07' AS TEST_ID,
    'Stream has been consumed' AS TEST_NAME,
    SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM') AS HAS_DATA,
    CASE WHEN SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM') = FALSE
         THEN 'PASS — stream consumed'
         ELSE 'INFO — stream still has data (task may not have run yet)' END AS TEST_RESULT;

-- =============================================================================
-- END OF INCREMENTAL BATCH TEST
-- =============================================================================
