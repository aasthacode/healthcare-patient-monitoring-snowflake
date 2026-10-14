-- =============================================================================
-- File        : 01_bronze_validation.sql
-- Layer       : Testing — Bronze
-- Description : Validates that source data was loaded correctly into Bronze.
--               Each test includes the expected outcome in a comment.
--               Run after 02_bronze/02_load_bronze_data.sql.
--
-- IMPORTANT: These are EXPECTED outcomes. Actual pass/fail status must be
--            confirmed by running these queries in a live Snowflake account.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- TEST B-01: Correct row count — RAW_PATIENTS
-- Expected: 30 rows
-- =============================================================================
SELECT 'B-01' AS TEST_ID, 'RAW_PATIENTS row count' AS TEST_NAME,
       COUNT(*) AS ACTUAL_COUNT,
       CASE WHEN COUNT(*) = 30 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM BRONZE.RAW_PATIENTS;


-- =============================================================================
-- TEST B-02: Correct row count — RAW_DEVICES
-- Expected: 15 rows
-- =============================================================================
SELECT 'B-02' AS TEST_ID, 'RAW_DEVICES row count' AS TEST_NAME,
       COUNT(*) AS ACTUAL_COUNT,
       CASE WHEN COUNT(*) = 15 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM BRONZE.RAW_DEVICES;


-- =============================================================================
-- TEST B-03: Correct row count — RAW_READINGS
-- Expected: 700 rows (all rows including intentionally malformed ones)
-- =============================================================================
SELECT 'B-03' AS TEST_ID, 'RAW_READINGS row count' AS TEST_NAME,
       COUNT(*) AS ACTUAL_COUNT,
       CASE WHEN COUNT(*) = 700 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM BRONZE.RAW_READINGS;


-- =============================================================================
-- TEST B-04: Malformed rows preserved as VARCHAR strings (not silently dropped)
-- Checks that the intentionally bad rows survived the COPY INTO load.
-- Expected: all 15 problem row reading_ids are present in Bronze.
-- =============================================================================
SELECT 'B-04' AS TEST_ID, 'Malformed rows present in Bronze' AS TEST_NAME,
       COUNT(*) AS PROBLEM_ROWS_FOUND,
       CASE WHEN COUNT(*) = 15 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM BRONZE.RAW_READINGS
WHERE READING_ID IN (
    'R0683','R0684','R0685','R0686','R0687','R0688','R0689','R0690',
    'R0691','R0692','R0693','R0694','R0695','R0696','R0700',
    'R0680','R0681','R0682'
);
-- Note: R0680-R0682 are duplicate readings, R0695/R0696 are exact duplicates


-- =============================================================================
-- TEST B-05: Heart rate stored as VARCHAR (not automatically cast)
-- R0685 has heart_rate = 'abc' — it must appear as the string 'abc', not NULL.
-- Expected: 1 row with HEART_RATE = 'abc'
-- =============================================================================
SELECT 'B-05' AS TEST_ID, 'Non-numeric heart_rate preserved as VARCHAR' AS TEST_NAME,
       READING_ID, HEART_RATE,
       CASE WHEN HEART_RATE = 'abc' THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM BRONZE.RAW_READINGS
WHERE READING_ID = 'R0685';


-- =============================================================================
-- TEST B-06: Metadata columns populated
-- _SOURCE_FILE and _INGESTION_TIMESTAMP should be non-null for all Bronze rows.
-- Expected: 0 rows with NULL metadata
-- =============================================================================
SELECT 'B-06' AS TEST_ID, 'Bronze metadata columns populated' AS TEST_NAME,
       COUNT(*) AS ROWS_WITH_NULL_METADATA,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM BRONZE.RAW_READINGS
WHERE _SOURCE_FILE IS NULL OR _INGESTION_TIMESTAMP IS NULL;


-- =============================================================================
-- TEST B-07: No data in Silver yet (if run before Silver scripts)
-- Or alternatively: Silver does not contain Bronze's malformed rows.
-- Expected: R0685 (heart_rate = 'abc') should NOT exist in Silver.
-- =============================================================================
SELECT 'B-07' AS TEST_ID, 'Malformed row R0685 absent from Silver' AS TEST_NAME,
       COUNT(*) AS FOUND_IN_SILVER,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS
WHERE READING_ID = 'R0685';


-- =============================================================================
-- TEST B-08: Bronze load is idempotent — rerunning COPY INTO does not duplicate
-- This test requires running 02_load_bronze_data.sql a second time, then:
-- Expected: row count still 700, not 1400
-- =============================================================================
SELECT 'B-08' AS TEST_ID, 'Bronze load idempotency (no duplicates on rerun)' AS TEST_NAME,
       COUNT(*) AS ACTUAL_COUNT,
       CASE WHEN COUNT(*) = 700 THEN 'PASS'
            WHEN COUNT(*) = 1400 THEN 'FAIL - data was loaded twice'
            ELSE 'CHECK - unexpected count' END AS TEST_RESULT
FROM BRONZE.RAW_READINGS;

-- =============================================================================
-- END OF BRONZE VALIDATION
-- =============================================================================
