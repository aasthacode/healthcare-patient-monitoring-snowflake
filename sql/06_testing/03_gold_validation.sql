-- =============================================================================
-- File        : 03_gold_validation.sql
-- Layer       : Testing — Gold
-- Description : Validates Gold layer aggregations and analytical tables.
--               Run after all 04_gold/ scripts.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- TEST G-01: DAILY_PATIENT_SUMMARY is not empty
-- Expected: at least 1 row
-- =============================================================================
SELECT 'G-01' AS TEST_ID, 'DAILY_PATIENT_SUMMARY populated' AS TEST_NAME,
       COUNT(*) AS ROW_COUNT,
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM GOLD.DAILY_PATIENT_SUMMARY;


-- =============================================================================
-- TEST G-02: Each (PATIENT_ID, READING_DATE) combination is unique in Gold
-- Expected: 0 duplicate combinations
-- =============================================================================
SELECT 'G-02' AS TEST_ID, 'DAILY_PATIENT_SUMMARY unique per patient-date' AS TEST_NAME,
       COUNT(*) AS DUPLICATE_COMBOS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM (
    SELECT PATIENT_ID, READING_DATE, COUNT(*) AS CNT
    FROM GOLD.DAILY_PATIENT_SUMMARY
    GROUP BY PATIENT_ID, READING_DATE
    HAVING COUNT(*) > 1
);


-- =============================================================================
-- TEST G-03: Gold reading count reconciles with Silver reading count
-- SUM(TOTAL_READINGS) in Gold must equal COUNT(*) in Silver.
-- Expected: both numbers are equal
-- =============================================================================
SELECT
    'G-03' AS TEST_ID,
    'Gold vs Silver reading count reconciliation' AS TEST_NAME,
    gold_total,
    silver_total,
    CASE WHEN gold_total = silver_total THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM (
    SELECT
        (SELECT SUM(TOTAL_READINGS) FROM GOLD.DAILY_PATIENT_SUMMARY) AS gold_total,
        (SELECT COUNT(*)             FROM SILVER.CLEAN_READINGS)       AS silver_total
);


-- =============================================================================
-- TEST G-04: READING_ALERTS is not empty (we expect alert flags in the data)
-- Expected: at least 1 alert row
-- =============================================================================
SELECT 'G-04' AS TEST_ID, 'READING_ALERTS populated' AS TEST_NAME,
       COUNT(*) AS ALERT_COUNT,
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM GOLD.READING_ALERTS;


-- =============================================================================
-- TEST G-05: Each (READING_ID, METRIC_NAME) is unique in READING_ALERTS
-- Expected: 0 duplicate combinations
-- =============================================================================
SELECT 'G-05' AS TEST_ID, 'READING_ALERTS unique per reading-metric' AS TEST_NAME,
       COUNT(*) AS DUPLICATE_COMBOS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM (
    SELECT READING_ID, METRIC_NAME, COUNT(*) AS CNT
    FROM GOLD.READING_ALERTS
    GROUP BY READING_ID, METRIC_NAME
    HAVING COUNT(*) > 1
);


-- =============================================================================
-- TEST G-06: PATIENT_TRENDS has LAG values populated for non-first days
-- The first reading day for each patient has NULL prev values (expected).
-- All subsequent days should have non-null prev values.
-- Expected: 0 rows where PREV_AVG_HEART_RATE is NULL on a non-first day.
-- =============================================================================
SELECT 'G-06' AS TEST_ID, 'LAG values populated for non-first days' AS TEST_NAME,
       COUNT(*) AS ROWS_WITHOUT_LAG,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM (
    SELECT
        pt.PATIENT_ID,
        pt.READING_DATE,
        pt.PREV_AVG_HEART_RATE,
        ROW_NUMBER() OVER (PARTITION BY pt.PATIENT_ID ORDER BY pt.READING_DATE ASC) AS DAY_RANK
    FROM GOLD.PATIENT_TRENDS pt
)
WHERE DAY_RANK > 1 AND PREV_AVG_HEART_RATE IS NULL;


-- =============================================================================
-- TEST G-07: DAILY_PATIENT_SUMMARY avg values are within expected ranges
-- Averages should fall within the Silver plausibility bounds since Silver
-- already filtered out-of-range values.
-- =============================================================================
SELECT 'G-07' AS TEST_ID, 'Gold summary averages within plausibility range' AS TEST_NAME,
       COUNT(*) AS OUT_OF_RANGE_ROWS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM GOLD.DAILY_PATIENT_SUMMARY
WHERE AVG_HEART_RATE    NOT BETWEEN 40  AND 180
   OR AVG_GLUCOSE_LEVEL NOT BETWEEN 50  AND 600
   OR AVG_OXYGEN_SAT    NOT BETWEEN 85  AND 100;


-- =============================================================================
-- TEST G-08: PATIENT_TRENDS row count matches DAILY_PATIENT_SUMMARY row count
-- Both tables represent one row per patient per day.
-- Expected: counts are equal
-- =============================================================================
SELECT
    'G-08' AS TEST_ID,
    'PATIENT_TRENDS row count matches DAILY_PATIENT_SUMMARY' AS TEST_NAME,
    summary_count,
    trends_count,
    CASE WHEN summary_count = trends_count THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM (
    SELECT
        (SELECT COUNT(*) FROM GOLD.DAILY_PATIENT_SUMMARY) AS summary_count,
        (SELECT COUNT(*) FROM GOLD.PATIENT_TRENDS)         AS trends_count
);


-- =============================================================================
-- TEST G-09: Gold is re-runnable — MERGE produces no duplicates
-- Run all 04_gold/ scripts a second time, then:
-- Expected: row count in DAILY_PATIENT_SUMMARY unchanged
-- =============================================================================
SELECT 'G-09' AS TEST_ID, 'DAILY_PATIENT_SUMMARY re-run idempotency' AS TEST_NAME,
       COUNT(SUMMARY_ID)                   AS TOTAL_ROWS,
       COUNT(DISTINCT PATIENT_ID || '|' || READING_DATE::VARCHAR) AS DISTINCT_PATIENT_DATES,
       CASE WHEN COUNT(SUMMARY_ID) =
                 COUNT(DISTINCT PATIENT_ID || '|' || READING_DATE::VARCHAR)
            THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM GOLD.DAILY_PATIENT_SUMMARY;

-- =============================================================================
-- END OF GOLD VALIDATION
-- =============================================================================
