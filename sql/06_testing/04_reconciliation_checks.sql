-- =============================================================================
-- File        : 04_reconciliation_checks.sql
-- Layer       : Testing — Cross-layer reconciliation
-- Description : Cross-layer data quality checks that verify the entire pipeline
--               is consistent. Run after all pipeline scripts have completed.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- CHECK RC-01: Bronze = Silver accepted + CONTROL rejected (readings)
-- Every Bronze reading row must be accounted for: either accepted into Silver
-- or logged as rejected in CONTROL.
-- Expected: BRONZE_TOTAL = SILVER_ACCEPTED + CONTROL_REJECTED
-- =============================================================================
SELECT
    'RC-01' AS CHECK_ID,
    'Bronze = Silver + Rejected (readings)' AS CHECK_NAME,
    bronze_total,
    silver_accepted,
    control_rejected,
    silver_accepted + control_rejected AS total_accounted_for,
    CASE WHEN bronze_total = silver_accepted + control_rejected
         THEN 'PASS' ELSE 'FAIL — rows unaccounted for' END AS CHECK_RESULT
FROM (
    SELECT
        (SELECT COUNT(*) FROM BRONZE.RAW_READINGS)                                             AS bronze_total,
        (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS)                                           AS silver_accepted,
        (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE SOURCE_TABLE = 'BRONZE.RAW_READINGS') AS control_rejected
);


-- =============================================================================
-- CHECK RC-02: No reading_id appears in both Silver and REJECTED_RECORDS
-- A reading should never be both accepted AND rejected.
-- Expected: 0 rows
-- =============================================================================
SELECT
    'RC-02' AS CHECK_ID,
    'No reading in both Silver and Rejected' AS CHECK_NAME,
    COUNT(*) AS CROSSOVER_COUNT,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS CHECK_RESULT
FROM SILVER.CLEAN_READINGS cr
JOIN CONTROL.REJECTED_RECORDS rr
    ON rr.READING_ID = cr.READING_ID
   AND rr.SOURCE_TABLE = 'BRONZE.RAW_READINGS';


-- =============================================================================
-- CHECK RC-03: Gold aggregate count equals Silver reading count
-- =============================================================================
SELECT
    'RC-03' AS CHECK_ID,
    'Gold total readings = Silver row count' AS CHECK_NAME,
    gold_sum,
    silver_count,
    CASE WHEN gold_sum = silver_count THEN 'PASS' ELSE 'FAIL' END AS CHECK_RESULT
FROM (
    SELECT
        (SELECT SUM(TOTAL_READINGS) FROM GOLD.DAILY_PATIENT_SUMMARY) AS gold_sum,
        (SELECT COUNT(*)             FROM SILVER.CLEAN_READINGS)       AS silver_count
);


-- =============================================================================
-- CHECK RC-04: All rejection reasons are from the documented catalogue
-- Unknown reason codes would indicate a bug in the Silver logic.
-- Expected: 0 rows with undocumented reason codes
-- =============================================================================
SELECT
    'RC-04' AS CHECK_ID,
    'All rejection reasons are documented' AS CHECK_NAME,
    COUNT(*) AS UNDOCUMENTED_REASONS,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS CHECK_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE REJECTION_REASON NOT IN (
    'MISSING_READING_ID', 'MISSING_PATIENT_ID', 'MISSING_DEVICE_ID',
    'INVALID_TIMESTAMP', 'INVALID_HEART_RATE', 'INVALID_GLUCOSE', 'INVALID_OXYGEN_SAT',
    'UNKNOWN_PATIENT_ID', 'UNKNOWN_DEVICE_ID',
    'HEART_RATE_OUT_OF_RANGE', 'GLUCOSE_OUT_OF_RANGE', 'OXYGEN_SAT_OUT_OF_RANGE',
    'DUPLICATE_READING_ID',
    -- Patient rules
    'MISSING_PATIENT_ID', 'INVALID_PATIENT_ID_FORMAT', 'INVALID_AGE_FORMAT',
    'AGE_OUT_OF_RANGE', 'INVALID_REGISTRATION_DATE',
    -- Device rules
    'MISSING_DEVICE_ID', 'MISSING_DEVICE_TYPE', 'INVALID_DEPLOYMENT_DATE'
);


-- =============================================================================
-- CHECK RC-05: All Silver readings have a corresponding Gold summary row
-- Every patient-date combination in Silver should have a Gold summary.
-- Expected: 0 Silver patient-dates missing from Gold
-- =============================================================================
SELECT
    'RC-05' AS CHECK_ID,
    'All Silver patient-dates have Gold summary' AS CHECK_NAME,
    COUNT(*) AS MISSING_IN_GOLD,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS CHECK_RESULT
FROM (
    SELECT DISTINCT PATIENT_ID, READING_DATE FROM SILVER.CLEAN_READINGS
) silver_dates
WHERE NOT EXISTS (
    SELECT 1 FROM GOLD.DAILY_PATIENT_SUMMARY dps
    WHERE dps.PATIENT_ID   = silver_dates.PATIENT_ID
      AND dps.READING_DATE = silver_dates.READING_DATE
);


-- =============================================================================
-- CHECK RC-06: Pipeline run log shows no FAILED runs
-- Expected: 0 rows with STATUS = 'FAILED'
-- =============================================================================
SELECT
    'RC-06' AS CHECK_ID,
    'No failed pipeline runs' AS CHECK_NAME,
    COUNT(*) AS FAILED_RUNS,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS CHECK_RESULT
FROM CONTROL.PIPELINE_RUN_LOG
WHERE STATUS = 'FAILED';

-- If this fails, view the failures:
SELECT RUN_ID, PIPELINE_NAME, STARTED_AT, ERROR_MESSAGE
FROM CONTROL.PIPELINE_RUN_LOG
WHERE STATUS = 'FAILED'
ORDER BY STARTED_AT DESC;


-- =============================================================================
-- CHECK RC-07: Rejection summary — how many of each type
-- Informational — helps characterise the quality of the source data.
-- =============================================================================
SELECT
    REJECTION_REASON,
    COUNT(*) AS COUNT,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS PCT_OF_ALL_REJECTIONS
FROM CONTROL.REJECTED_RECORDS
GROUP BY REJECTION_REASON
ORDER BY COUNT DESC;


-- =============================================================================
-- CHECK RC-08: No duplicate READING_IDs in Silver (primary key integrity)
-- Expected: 0 reading_ids with count > 1
-- =============================================================================
SELECT
    'RC-08' AS CHECK_ID,
    'No duplicate READING_IDs in Silver' AS CHECK_NAME,
    COUNT(*) AS DUPLICATE_IDS,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS CHECK_RESULT
FROM (
    SELECT READING_ID, COUNT(*) AS CNT
    FROM SILVER.CLEAN_READINGS
    GROUP BY READING_ID
    HAVING COUNT(*) > 1
);

-- =============================================================================
-- END OF RECONCILIATION CHECKS
-- =============================================================================
