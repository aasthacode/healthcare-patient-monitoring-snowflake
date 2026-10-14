-- =============================================================================
-- File        : 01_analytical_queries.sql
-- Layer       : Reports (sql/07_reports/)
-- Description : Standalone SQL queries that demonstrate the finished pipeline.
--               Each query answers a specific analytical question about the data.
--               Run these in any order after the full pipeline has been executed.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;


-- =============================================================================
-- QUERY 1: Each patient's daily average measurements
-- Question: "What are each patient's daily average heart rate, glucose, and SpO2?"
-- Source: GOLD.DAILY_PATIENT_SUMMARY (pre-aggregated)
-- =============================================================================
SELECT
    dps.PATIENT_ID,
    cp.AGE,
    cp.GENDER,
    cp.CITY,
    dps.READING_DATE,
    dps.TOTAL_READINGS,
    dps.AVG_HEART_RATE,
    dps.AVG_GLUCOSE_LEVEL,
    dps.AVG_OXYGEN_SAT
FROM GOLD.DAILY_PATIENT_SUMMARY  dps
JOIN SILVER.CLEAN_PATIENTS       cp ON cp.PATIENT_ID = dps.PATIENT_ID
ORDER BY dps.PATIENT_ID, dps.READING_DATE;


-- =============================================================================
-- QUERY 2: Readings that crossed illustrative example thresholds
-- Question: "Which readings matched the configured example threshold rules?"
-- Note: FOR DEMONSTRATION ONLY — not clinical diagnoses.
-- =============================================================================
SELECT
    ra.ALERT_ID,
    ra.READING_ID,
    ra.PATIENT_ID,
    cp.AGE,
    ra.READING_TIMESTAMP,
    ra.METRIC_NAME,
    ra.OBSERVED_VALUE,
    ra.THRESHOLD_TRIGGERED,
    ra.ALERT_CATEGORY
FROM GOLD.READING_ALERTS    ra
JOIN SILVER.CLEAN_PATIENTS  cp ON cp.PATIENT_ID = ra.PATIENT_ID
ORDER BY ra.ALERT_CATEGORY, ra.METRIC_NAME, ra.PATIENT_ID, ra.READING_TIMESTAMP;


-- =============================================================================
-- QUERY 3: Day-over-day metric changes per patient
-- Question: "How do average readings change from one day to the next?"
-- Source: GOLD.PATIENT_TRENDS (uses LAG window function)
-- =============================================================================
SELECT
    pt.PATIENT_ID,
    cp.AGE,
    pt.READING_DATE,
    pt.AVG_HEART_RATE,
    pt.PREV_AVG_HEART_RATE,
    pt.DELTA_HEART_RATE,
    pt.AVG_GLUCOSE_LEVEL,
    pt.PREV_AVG_GLUCOSE_LEVEL,
    pt.DELTA_GLUCOSE_LEVEL,
    pt.AVG_OXYGEN_SAT,
    pt.PREV_AVG_OXYGEN_SAT,
    pt.DELTA_OXYGEN_SAT
FROM GOLD.PATIENT_TRENDS     pt
JOIN SILVER.CLEAN_PATIENTS   cp ON cp.PATIENT_ID = pt.PATIENT_ID
ORDER BY pt.PATIENT_ID, pt.READING_DATE;


-- =============================================================================
-- QUERY 4: Accepted vs. rejected record counts
-- Question: "How many records were accepted into Silver and how many were rejected?"
-- =============================================================================
SELECT
    'CLEAN_PATIENTS'  AS LAYER_TABLE,  COUNT(*) AS ROW_COUNT FROM SILVER.CLEAN_PATIENTS
UNION ALL
SELECT 'CLEAN_DEVICES',                COUNT(*) FROM SILVER.CLEAN_DEVICES
UNION ALL
SELECT 'CLEAN_READINGS',               COUNT(*) FROM SILVER.CLEAN_READINGS
UNION ALL
SELECT 'REJECTED_RECORDS (total)',     COUNT(*) FROM CONTROL.REJECTED_RECORDS
ORDER BY LAYER_TABLE;


-- =============================================================================
-- QUERY 5: Most common data quality problems
-- Question: "What are the most common data quality problems in the readings?"
-- =============================================================================
SELECT
    REJECTION_REASON,
    SOURCE_TABLE,
    COUNT(*) AS OCCURRENCE_COUNT,
    ROUND(COUNT(*) * 100.0 /
        SUM(COUNT(*)) OVER (PARTITION BY SOURCE_TABLE), 2) AS PCT_OF_TABLE_REJECTIONS
FROM CONTROL.REJECTED_RECORDS
GROUP BY REJECTION_REASON, SOURCE_TABLE
ORDER BY SOURCE_TABLE, OCCURRENCE_COUNT DESC;


-- =============================================================================
-- QUERY 6: Readings processed per day (across all patients)
-- Question: "How many readings were processed per calendar day?"
-- =============================================================================
SELECT
    READING_DATE,
    SUM(TOTAL_READINGS) AS TOTAL_READINGS_FOR_DAY,
    COUNT(DISTINCT PATIENT_ID) AS PATIENTS_WITH_READINGS
FROM GOLD.DAILY_PATIENT_SUMMARY
GROUP BY READING_DATE
ORDER BY READING_DATE;


-- =============================================================================
-- QUERY 7: Patients or devices with missing/invalid references
-- Question: "Are there readings rejected due to unknown patient or device IDs?"
-- =============================================================================
SELECT
    rr.REJECTION_REASON,
    rr.READING_ID,
    rr.PATIENT_ID,
    rr.DEVICE_ID,
    rr.RAW_ROW_SNAPSHOT,
    rr.REJECTED_AT
FROM CONTROL.REJECTED_RECORDS rr
WHERE rr.REJECTION_REASON IN ('UNKNOWN_PATIENT_ID', 'UNKNOWN_DEVICE_ID',
                               'MISSING_PATIENT_ID', 'MISSING_DEVICE_ID')
ORDER BY rr.REJECTION_REASON, rr.REJECTED_AT;


-- =============================================================================
-- QUERY 8: Gold aggregate reconciliation with Silver
-- Question: "Do Gold aggregates reconcile with the cleaned Silver data?"
-- This is a critical validation query — the sums should match.
-- =============================================================================
SELECT
    'Gold DAILY_PATIENT_SUMMARY total readings' AS CHECK_DESCRIPTION,
    SUM(TOTAL_READINGS) AS COUNT_FROM_GOLD
FROM GOLD.DAILY_PATIENT_SUMMARY
UNION ALL
SELECT
    'Silver CLEAN_READINGS row count',
    COUNT(*)
FROM SILVER.CLEAN_READINGS;
-- Both numbers should be identical.


-- =============================================================================
-- QUERY 9: Patient-level summary — total readings and alert flags
-- High-level view of each patient across the entire monitoring period.
-- =============================================================================
SELECT
    cp.PATIENT_ID,
    cp.AGE,
    cp.GENDER,
    cp.CITY,
    SUM(dps.TOTAL_READINGS)          AS TOTAL_READINGS,
    MIN(dps.READING_DATE)            AS FIRST_READING_DATE,
    MAX(dps.READING_DATE)            AS LAST_READING_DATE,
    ROUND(AVG(dps.AVG_HEART_RATE),2) AS OVERALL_AVG_HR,
    ROUND(AVG(dps.AVG_GLUCOSE_LEVEL),2) AS OVERALL_AVG_GLUCOSE,
    ROUND(AVG(dps.AVG_OXYGEN_SAT),2)    AS OVERALL_AVG_O2,
    SUM(dps.HIGH_HR_READINGS)        AS TOTAL_HIGH_HR_FLAGS,
    SUM(dps.LOW_OXYGEN_READINGS)     AS TOTAL_LOW_O2_FLAGS,
    SUM(dps.HIGH_GLUCOSE_READINGS)   AS TOTAL_HIGH_GLUCOSE_FLAGS
FROM GOLD.DAILY_PATIENT_SUMMARY dps
JOIN SILVER.CLEAN_PATIENTS      cp ON cp.PATIENT_ID = dps.PATIENT_ID
GROUP BY cp.PATIENT_ID, cp.AGE, cp.GENDER, cp.CITY
ORDER BY TOTAL_HIGH_HR_FLAGS DESC, cp.PATIENT_ID;


-- =============================================================================
-- QUERY 10: Pipeline run history
-- Shows when each pipeline step ran and how many rows were processed.
-- =============================================================================
SELECT
    PIPELINE_NAME,
    LAYER,
    STATUS,
    STARTED_AT,
    COMPLETED_AT,
    ROWS_INPUT,
    ROWS_ACCEPTED,
    ROWS_REJECTED,
    ROWS_INSERTED,
    ERROR_MESSAGE
FROM CONTROL.PIPELINE_RUN_LOG
ORDER BY STARTED_AT DESC;


-- =============================================================================
-- QUERY 11: Devices with the most rejected readings
-- Useful for investigating whether a specific device produces bad data.
-- =============================================================================
SELECT
    rr.DEVICE_ID,
    cd.DEVICE_TYPE,
    cd.MANUFACTURER,
    cd.DEVICE_STATUS,
    COUNT(*) AS REJECTED_READINGS
FROM CONTROL.REJECTED_RECORDS rr
LEFT JOIN SILVER.CLEAN_DEVICES cd ON cd.DEVICE_ID = rr.DEVICE_ID
WHERE rr.SOURCE_TABLE = 'BRONZE.RAW_READINGS'
  AND rr.DEVICE_ID IS NOT NULL
GROUP BY rr.DEVICE_ID, cd.DEVICE_TYPE, cd.MANUFACTURER, cd.DEVICE_STATUS
ORDER BY REJECTED_READINGS DESC;


-- =============================================================================
-- QUERY 12: Reading alert details with patient demographics
-- Full detail of each alert flag joined to patient info.
-- FOR DEMONSTRATION ONLY — not clinical diagnoses.
-- =============================================================================
SELECT
    ra.READING_ID,
    ra.PATIENT_ID,
    cp.AGE,
    cp.GENDER,
    cp.CITY,
    ra.READING_TIMESTAMP::DATE  AS READING_DATE,
    ra.METRIC_NAME,
    ra.OBSERVED_VALUE,
    ra.THRESHOLD_TRIGGERED,
    ra.ALERT_CATEGORY
FROM GOLD.READING_ALERTS    ra
JOIN SILVER.CLEAN_PATIENTS  cp ON cp.PATIENT_ID = ra.PATIENT_ID
WHERE ra.ALERT_CATEGORY = 'VERY_HIGH'
ORDER BY ra.READING_TIMESTAMP DESC;

-- =============================================================================
-- END OF REPORTS
-- =============================================================================
