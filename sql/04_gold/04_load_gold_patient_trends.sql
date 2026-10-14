-- =============================================================================
-- File        : 04_load_gold_patient_trends.sql
-- Layer       : Gold
-- Description : Populates GOLD.PATIENT_TRENDS using the LAG window function to
--               compare each patient's daily averages to the previous day's
--               averages and compute day-over-day deltas.
-- Run order   : 13 — run after 04_gold/03_load_gold_reading_alerts.sql
-- Idempotent  : Yes — MERGE on (PATIENT_ID, READING_DATE).
--
-- SQL concepts demonstrated:
--   - CTE (WITH clause) for readability
--   - GROUP BY aggregation
--   - LAG() window function for accessing the previous row's value
--   - PARTITION BY to reset the window per patient
--   - ORDER BY inside OVER() clause to control row ordering within the partition
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- MERGE patient trend rows.
--
-- Source subquery explanation:
--
--   Step 1 (DAILY_AVGS CTE):
--     Compute the daily average for each metric per patient from CLEAN_READINGS.
--     This gives us one row per patient per day.
--
--   Step 2 (TRENDS_WITH_LAG CTE):
--     Apply LAG() to look back one row (i.e., the previous day that had readings)
--     within each patient's partition.
--
--   LAG(column, 1) OVER (PARTITION BY PATIENT_ID ORDER BY READING_DATE ASC)
--     - PARTITION BY PATIENT_ID: restart the window for each patient
--     - ORDER BY READING_DATE ASC: go day by day in chronological order
--     - LAG(..., 1): get the value from the PREVIOUS row in the partition
--     - The first day for each patient will have NULL for prev values (no prior day)
--
--   Step 3: Compute deltas (current minus previous).
-- =============================================================================
MERGE INTO GOLD.PATIENT_TRENDS AS target
USING (
    WITH DAILY_AVGS AS (
        -- Aggregate to one row per patient per day
        SELECT
            cr.PATIENT_ID,
            cr.READING_DATE,
            ROUND(AVG(cr.HEART_RATE),       2) AS AVG_HEART_RATE,
            ROUND(AVG(cr.GLUCOSE_LEVEL),    2) AS AVG_GLUCOSE_LEVEL,
            ROUND(AVG(cr.OXYGEN_SATURATION),2) AS AVG_OXYGEN_SAT
        FROM SILVER.CLEAN_READINGS cr
        GROUP BY cr.PATIENT_ID, cr.READING_DATE
    ),
    TRENDS_WITH_LAG AS (
        SELECT
            d.PATIENT_ID,
            d.READING_DATE,
            d.AVG_HEART_RATE,
            d.AVG_GLUCOSE_LEVEL,
            d.AVG_OXYGEN_SAT,
            -- LAG retrieves the value from the previous row in the window
            LAG(d.AVG_HEART_RATE,       1) OVER (PARTITION BY d.PATIENT_ID ORDER BY d.READING_DATE ASC) AS PREV_AVG_HEART_RATE,
            LAG(d.AVG_GLUCOSE_LEVEL,    1) OVER (PARTITION BY d.PATIENT_ID ORDER BY d.READING_DATE ASC) AS PREV_AVG_GLUCOSE_LEVEL,
            LAG(d.AVG_OXYGEN_SAT,       1) OVER (PARTITION BY d.PATIENT_ID ORDER BY d.READING_DATE ASC) AS PREV_AVG_OXYGEN_SAT
        FROM DAILY_AVGS d
    )
    SELECT
        t.PATIENT_ID,
        t.READING_DATE,
        t.AVG_HEART_RATE,
        t.AVG_GLUCOSE_LEVEL,
        t.AVG_OXYGEN_SAT,
        t.PREV_AVG_HEART_RATE,
        t.PREV_AVG_GLUCOSE_LEVEL,
        t.PREV_AVG_OXYGEN_SAT,
        -- Delta = current - previous (NULL if no previous day exists)
        ROUND(t.AVG_HEART_RATE    - t.PREV_AVG_HEART_RATE,    2) AS DELTA_HEART_RATE,
        ROUND(t.AVG_GLUCOSE_LEVEL - t.PREV_AVG_GLUCOSE_LEVEL, 2) AS DELTA_GLUCOSE_LEVEL,
        ROUND(t.AVG_OXYGEN_SAT    - t.PREV_AVG_OXYGEN_SAT,    2) AS DELTA_OXYGEN_SAT
    FROM TRENDS_WITH_LAG t
) AS source
ON target.PATIENT_ID    = source.PATIENT_ID
   AND target.READING_DATE = source.READING_DATE
WHEN MATCHED THEN UPDATE SET
    target.AVG_HEART_RATE         = source.AVG_HEART_RATE,
    target.AVG_GLUCOSE_LEVEL      = source.AVG_GLUCOSE_LEVEL,
    target.AVG_OXYGEN_SAT         = source.AVG_OXYGEN_SAT,
    target.PREV_AVG_HEART_RATE    = source.PREV_AVG_HEART_RATE,
    target.PREV_AVG_GLUCOSE_LEVEL = source.PREV_AVG_GLUCOSE_LEVEL,
    target.PREV_AVG_OXYGEN_SAT    = source.PREV_AVG_OXYGEN_SAT,
    target.DELTA_HEART_RATE       = source.DELTA_HEART_RATE,
    target.DELTA_GLUCOSE_LEVEL    = source.DELTA_GLUCOSE_LEVEL,
    target.DELTA_OXYGEN_SAT       = source.DELTA_OXYGEN_SAT,
    target.TREND_CREATED_AT       = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    PATIENT_ID, READING_DATE,
    AVG_HEART_RATE, AVG_GLUCOSE_LEVEL, AVG_OXYGEN_SAT,
    PREV_AVG_HEART_RATE, PREV_AVG_GLUCOSE_LEVEL, PREV_AVG_OXYGEN_SAT,
    DELTA_HEART_RATE, DELTA_GLUCOSE_LEVEL, DELTA_OXYGEN_SAT,
    TREND_CREATED_AT
) VALUES (
    source.PATIENT_ID, source.READING_DATE,
    source.AVG_HEART_RATE, source.AVG_GLUCOSE_LEVEL, source.AVG_OXYGEN_SAT,
    source.PREV_AVG_HEART_RATE, source.PREV_AVG_GLUCOSE_LEVEL, source.PREV_AVG_OXYGEN_SAT,
    source.DELTA_HEART_RATE, source.DELTA_GLUCOSE_LEVEL, source.DELTA_OXYGEN_SAT,
    CURRENT_TIMESTAMP()
);


-- =============================================================================
-- VALIDATION
-- =============================================================================
SELECT COUNT(*) AS trend_rows FROM GOLD.PATIENT_TRENDS;
-- Expected: same number of rows as DAILY_PATIENT_SUMMARY (one row per patient per day)

-- Verify LAG worked: the first day for each patient should have NULL prev values.
SELECT PATIENT_ID, READING_DATE,
       AVG_HEART_RATE, PREV_AVG_HEART_RATE, DELTA_HEART_RATE
FROM GOLD.PATIENT_TRENDS
WHERE PATIENT_ID = 'P001'
ORDER BY READING_DATE;
-- First row: PREV_AVG_HEART_RATE = NULL, DELTA_HEART_RATE = NULL
-- Subsequent rows: populated with previous day's average and the delta

-- Show patients with the largest day-over-day glucose swings:
SELECT PATIENT_ID, READING_DATE, AVG_GLUCOSE_LEVEL,
       PREV_AVG_GLUCOSE_LEVEL, DELTA_GLUCOSE_LEVEL
FROM GOLD.PATIENT_TRENDS
WHERE DELTA_GLUCOSE_LEVEL IS NOT NULL
ORDER BY ABS(DELTA_GLUCOSE_LEVEL) DESC
LIMIT 10;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
