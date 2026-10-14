-- =============================================================================
-- File        : 02_load_gold_daily_summary.sql
-- Layer       : Gold
-- Description : Populates GOLD.DAILY_PATIENT_SUMMARY from SILVER.CLEAN_READINGS.
--               Produces one row per patient per day with aggregate metrics and
--               counts of readings that cross illustrative example thresholds.
--               Uses MERGE for idempotency — safe to rerun.
-- Run order   : 11 — run after 04_gold/01_create_gold_tables.sql
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- Load current thresholds (illustrative values, NOT clinically validated)
SET HR_ALERT_MAX  = (SELECT ALERT_MAX FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'    AND IS_CURRENT = TRUE);
SET GL_ALERT_MAX  = (SELECT ALERT_MAX FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE);
-- Oxygen alert fires BELOW a minimum — handled with CASE in the query below.
-- Threshold used: oxygen_saturation < 92 (see DATA_DICTIONARY.md).

-- =============================================================================
-- MERGE into GOLD.DAILY_PATIENT_SUMMARY.
--
-- The source CTE (DAILY_AGG) groups CLEAN_READINGS by patient and date.
-- MERGE ensures that:
--   - On the first run, all rows are inserted.
--   - On subsequent runs (e.g., after late-arriving records update Silver),
--     existing rows are updated to reflect the new aggregates.
-- =============================================================================
MERGE INTO GOLD.DAILY_PATIENT_SUMMARY AS target
USING (
    -- Aggregate readings per patient per day
    SELECT
        cr.PATIENT_ID,
        cr.READING_DATE,
        COUNT(*)                                        AS TOTAL_READINGS,
        ROUND(AVG(cr.HEART_RATE),    2)                AS AVG_HEART_RATE,
        MIN(cr.HEART_RATE)                              AS MIN_HEART_RATE,
        MAX(cr.HEART_RATE)                              AS MAX_HEART_RATE,
        ROUND(AVG(cr.GLUCOSE_LEVEL), 2)                AS AVG_GLUCOSE_LEVEL,
        MIN(cr.GLUCOSE_LEVEL)                           AS MIN_GLUCOSE_LEVEL,
        MAX(cr.GLUCOSE_LEVEL)                           AS MAX_GLUCOSE_LEVEL,
        ROUND(AVG(cr.OXYGEN_SATURATION), 2)            AS AVG_OXYGEN_SAT,
        MIN(cr.OXYGEN_SATURATION)                       AS MIN_OXYGEN_SAT,
        MAX(cr.OXYGEN_SATURATION)                       AS MAX_OXYGEN_SAT,
        -- Count readings above illustrative high heart-rate alert threshold
        SUM(CASE WHEN cr.HEART_RATE > $HR_ALERT_MAX THEN 1 ELSE 0 END)  AS HIGH_HR_READINGS,
        -- Count readings with SpO2 below illustrative low-oxygen threshold (92)
        SUM(CASE WHEN cr.OXYGEN_SATURATION < 92       THEN 1 ELSE 0 END) AS LOW_OXYGEN_READINGS,
        -- Count readings above illustrative high glucose alert threshold
        SUM(CASE WHEN cr.GLUCOSE_LEVEL > $GL_ALERT_MAX THEN 1 ELSE 0 END) AS HIGH_GLUCOSE_READINGS
    FROM SILVER.CLEAN_READINGS cr
    GROUP BY cr.PATIENT_ID, cr.READING_DATE
) AS source
ON target.PATIENT_ID = source.PATIENT_ID
   AND target.READING_DATE = source.READING_DATE
WHEN MATCHED THEN UPDATE SET
    target.TOTAL_READINGS        = source.TOTAL_READINGS,
    target.AVG_HEART_RATE        = source.AVG_HEART_RATE,
    target.MIN_HEART_RATE        = source.MIN_HEART_RATE,
    target.MAX_HEART_RATE        = source.MAX_HEART_RATE,
    target.AVG_GLUCOSE_LEVEL     = source.AVG_GLUCOSE_LEVEL,
    target.MIN_GLUCOSE_LEVEL     = source.MIN_GLUCOSE_LEVEL,
    target.MAX_GLUCOSE_LEVEL     = source.MAX_GLUCOSE_LEVEL,
    target.AVG_OXYGEN_SAT        = source.AVG_OXYGEN_SAT,
    target.MIN_OXYGEN_SAT        = source.MIN_OXYGEN_SAT,
    target.MAX_OXYGEN_SAT        = source.MAX_OXYGEN_SAT,
    target.HIGH_HR_READINGS      = source.HIGH_HR_READINGS,
    target.LOW_OXYGEN_READINGS   = source.LOW_OXYGEN_READINGS,
    target.HIGH_GLUCOSE_READINGS = source.HIGH_GLUCOSE_READINGS,
    target.SUMMARY_CREATED_AT    = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    PATIENT_ID, READING_DATE, TOTAL_READINGS,
    AVG_HEART_RATE, MIN_HEART_RATE, MAX_HEART_RATE,
    AVG_GLUCOSE_LEVEL, MIN_GLUCOSE_LEVEL, MAX_GLUCOSE_LEVEL,
    AVG_OXYGEN_SAT, MIN_OXYGEN_SAT, MAX_OXYGEN_SAT,
    HIGH_HR_READINGS, LOW_OXYGEN_READINGS, HIGH_GLUCOSE_READINGS,
    SUMMARY_CREATED_AT
) VALUES (
    source.PATIENT_ID, source.READING_DATE, source.TOTAL_READINGS,
    source.AVG_HEART_RATE, source.MIN_HEART_RATE, source.MAX_HEART_RATE,
    source.AVG_GLUCOSE_LEVEL, source.MIN_GLUCOSE_LEVEL, source.MAX_GLUCOSE_LEVEL,
    source.AVG_OXYGEN_SAT, source.MIN_OXYGEN_SAT, source.MAX_OXYGEN_SAT,
    source.HIGH_HR_READINGS, source.LOW_OXYGEN_READINGS, source.HIGH_GLUCOSE_READINGS,
    CURRENT_TIMESTAMP()
);


-- =============================================================================
-- VALIDATION
-- =============================================================================
SELECT COUNT(*) AS daily_summary_rows FROM GOLD.DAILY_PATIENT_SUMMARY;
-- Expected: one row per patient per day; with 30 patients over ~22 days,
-- expect approximately 450–600 rows depending on which patients have readings each day.

-- Sample: P001 daily summary
SELECT PATIENT_ID, READING_DATE, TOTAL_READINGS,
       AVG_HEART_RATE, AVG_GLUCOSE_LEVEL, AVG_OXYGEN_SAT,
       HIGH_HR_READINGS, LOW_OXYGEN_READINGS, HIGH_GLUCOSE_READINGS
FROM GOLD.DAILY_PATIENT_SUMMARY
WHERE PATIENT_ID = 'P001'
ORDER BY READING_DATE;

-- Reconciliation: Gold total readings should equal Silver total readings
SELECT
    (SELECT SUM(TOTAL_READINGS) FROM GOLD.DAILY_PATIENT_SUMMARY) AS gold_total,
    (SELECT COUNT(*)             FROM SILVER.CLEAN_READINGS)       AS silver_total;
-- These two numbers should be equal.

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
