-- =============================================================================
-- File        : 03_load_gold_reading_alerts.sql
-- Layer       : Gold
-- Description : Populates GOLD.READING_ALERTS by flagging individual readings
--               that cross configurable illustrative thresholds.
--               A single reading may produce multiple alert rows (one per
--               triggered rule).
--               FOR DEMONSTRATION PURPOSES ONLY — not clinical diagnoses.
-- Run order   : 12 — run after 04_gold/02_load_gold_daily_summary.sql
-- Idempotent  : Yes — MERGE on (READING_ID, METRIC_NAME).
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- Load thresholds (illustrative example values, NOT clinically validated)
SET HR_ALERT_MIN  = (SELECT ALERT_MIN FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'    AND IS_CURRENT = TRUE);
SET HR_ALERT_MAX  = (SELECT ALERT_MAX FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'    AND IS_CURRENT = TRUE);
SET GL_ALERT_MIN  = (SELECT ALERT_MIN FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE);
SET GL_ALERT_MAX  = (SELECT ALERT_MAX FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE);
-- Oxygen: alert fires below 92 (hard-coded as an illustrative low threshold)

-- =============================================================================
-- MERGE alert rows.
--
-- The source CTE unpivots each reading into one row per triggered threshold rule.
-- UNION ALL is used to produce one row per metric per reading.
-- Only rows where the metric actually crosses the threshold are included.
-- =============================================================================
MERGE INTO GOLD.READING_ALERTS AS target
USING (
    -- Heart rate alerts
    SELECT
        cr.READING_ID,
        cr.PATIENT_ID,
        cr.READING_TIMESTAMP,
        'HEART_RATE'                                         AS METRIC_NAME,
        cr.HEART_RATE                                        AS OBSERVED_VALUE,
        CASE
            WHEN cr.HEART_RATE > $HR_ALERT_MAX
                THEN 'HEART_RATE > ' || $HR_ALERT_MAX::VARCHAR
            WHEN cr.HEART_RATE > $HR_ALERT_MIN
                THEN 'HEART_RATE > ' || $HR_ALERT_MIN::VARCHAR
        END                                                  AS THRESHOLD_TRIGGERED,
        CASE
            WHEN cr.HEART_RATE > $HR_ALERT_MAX THEN 'VERY_HIGH'
            WHEN cr.HEART_RATE > $HR_ALERT_MIN THEN 'ELEVATED'
        END                                                  AS ALERT_CATEGORY
    FROM SILVER.CLEAN_READINGS cr
    WHERE cr.HEART_RATE > $HR_ALERT_MIN   -- catches both ELEVATED and VERY_HIGH

    UNION ALL

    -- Glucose level alerts
    SELECT
        cr.READING_ID,
        cr.PATIENT_ID,
        cr.READING_TIMESTAMP,
        'GLUCOSE_LEVEL'                                      AS METRIC_NAME,
        cr.GLUCOSE_LEVEL                                     AS OBSERVED_VALUE,
        CASE
            WHEN cr.GLUCOSE_LEVEL > $GL_ALERT_MAX
                THEN 'GLUCOSE_LEVEL > ' || $GL_ALERT_MAX::VARCHAR
            WHEN cr.GLUCOSE_LEVEL > $GL_ALERT_MIN
                THEN 'GLUCOSE_LEVEL > ' || $GL_ALERT_MIN::VARCHAR
        END                                                  AS THRESHOLD_TRIGGERED,
        CASE
            WHEN cr.GLUCOSE_LEVEL > $GL_ALERT_MAX THEN 'VERY_HIGH'
            WHEN cr.GLUCOSE_LEVEL > $GL_ALERT_MIN THEN 'ELEVATED'
        END                                                  AS ALERT_CATEGORY
    FROM SILVER.CLEAN_READINGS cr
    WHERE cr.GLUCOSE_LEVEL > $GL_ALERT_MIN

    UNION ALL

    -- Low oxygen saturation alert (below illustrative threshold of 92)
    -- Note: ALERT_MIN for OXYGEN_SAT is NULL in QUALITY_THRESHOLDS (no lower alert).
    -- This is handled as a hard-coded illustrative rule here.
    -- To make this configurable, add an ALERT_MIN row for OXYGEN_SAT in QUALITY_THRESHOLDS.
    SELECT
        cr.READING_ID,
        cr.PATIENT_ID,
        cr.READING_TIMESTAMP,
        'OXYGEN_SAT'                                         AS METRIC_NAME,
        cr.OXYGEN_SATURATION                                 AS OBSERVED_VALUE,
        'OXYGEN_SAT < 92'                                    AS THRESHOLD_TRIGGERED,
        'LOW'                                                AS ALERT_CATEGORY
    FROM SILVER.CLEAN_READINGS cr
    WHERE cr.OXYGEN_SATURATION < 92

) AS source
ON target.READING_ID  = source.READING_ID
   AND target.METRIC_NAME = source.METRIC_NAME
WHEN MATCHED THEN UPDATE SET
    target.PATIENT_ID          = source.PATIENT_ID,
    target.READING_TIMESTAMP   = source.READING_TIMESTAMP,
    target.OBSERVED_VALUE      = source.OBSERVED_VALUE,
    target.THRESHOLD_TRIGGERED = source.THRESHOLD_TRIGGERED,
    target.ALERT_CATEGORY      = source.ALERT_CATEGORY,
    target.PROCESSED_AT        = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    READING_ID, PATIENT_ID, READING_TIMESTAMP, METRIC_NAME,
    OBSERVED_VALUE, THRESHOLD_TRIGGERED, ALERT_CATEGORY, PROCESSED_AT
) VALUES (
    source.READING_ID, source.PATIENT_ID, source.READING_TIMESTAMP, source.METRIC_NAME,
    source.OBSERVED_VALUE, source.THRESHOLD_TRIGGERED, source.ALERT_CATEGORY, CURRENT_TIMESTAMP()
);


-- =============================================================================
-- VALIDATION
-- =============================================================================
SELECT COUNT(*) AS total_alerts FROM GOLD.READING_ALERTS;

-- Alerts by category and metric:
SELECT ALERT_CATEGORY, METRIC_NAME, COUNT(*) AS ALERT_COUNT
FROM GOLD.READING_ALERTS
GROUP BY ALERT_CATEGORY, METRIC_NAME
ORDER BY ALERT_CATEGORY, METRIC_NAME;

-- Patients with the most alert flags:
SELECT PATIENT_ID, COUNT(*) AS ALERT_COUNT
FROM GOLD.READING_ALERTS
GROUP BY PATIENT_ID
ORDER BY ALERT_COUNT DESC
LIMIT 10;

-- Sample alert rows:
SELECT READING_ID, PATIENT_ID, METRIC_NAME, OBSERVED_VALUE,
       THRESHOLD_TRIGGERED, ALERT_CATEGORY
FROM GOLD.READING_ALERTS
ORDER BY PATIENT_ID, READING_ID
LIMIT 20;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
