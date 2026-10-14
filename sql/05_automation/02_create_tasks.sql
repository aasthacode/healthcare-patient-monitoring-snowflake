-- =============================================================================
-- File        : 02_create_tasks.sql
-- Layer       : Automation
-- Description : Creates the three Tasks that automate incremental processing.
--               Task dependency chain:
--
--                 SILVER_INCREMENTAL_TASK  (root — scheduled)
--                         │
--                         └─► GOLD_REFRESH_TASK  (child — triggered by parent success)
--                                     │
--                                     └─► PIPELINE_LOG_TASK  (child — triggered by parent)
--
-- IMPORTANT:
--   • Tasks are created in SUSPENDED state. You MUST run the RESUME commands
--     at the bottom of this script to activate them.
--   • Resume child tasks BEFORE the root task (bottom-up order).
--   • The EXECUTE TASK privilege must be granted at the account level by ACCOUNTADMIN:
--       GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
--
-- Run order   : After 05_automation/01_create_stream.sql
-- Idempotent  : Yes — uses CREATE OR REPLACE TASK.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;


-- =============================================================================
-- PREREQUISITE: Grant EXECUTE TASK privilege (run as ACCOUNTADMIN once).
-- Uncomment and run in Snowsight as ACCOUNTADMIN if not already granted:
-- =============================================================================
-- USE ROLE ACCOUNTADMIN;
-- GRANT EXECUTE TASK ON ACCOUNT TO ROLE SYSADMIN;
-- USE ROLE SYSADMIN;


-- =============================================================================
-- TASK 1: SILVER_INCREMENTAL_TASK (Root Task)
--
-- Purpose     : Consumes READINGS_STREAM; applies Silver cleaning rules to
--               new rows only; inserts valid rows into CLEAN_READINGS and
--               rejected rows into REJECTED_RECORDS.
-- Schedule    : Every 15 minutes.
-- WHEN clause : Only executes if the stream has new, unconsumed data.
--               This prevents unnecessary warehouse startup when no data arrived.
-- Warehouse   : Uses COMPUTE_WH. Change to your preferred warehouse.
-- =============================================================================
CREATE OR REPLACE TASK HEALTHCARE_MONITORING_DB.PUBLIC.SILVER_INCREMENTAL_TASK
    WAREHOUSE   = COMPUTE_WH
    SCHEDULE    = '15 MINUTE'
    COMMENT     = 'Root task. Runs every 15 minutes. Consumes READINGS_STREAM and incrementally loads new rows into SILVER.CLEAN_READINGS.'
    WHEN SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM')
AS
-- =============================================================================
-- Task body: incremental Silver transformation for new readings only.
--
-- Design:
--   1. Read new rows from the stream into a temporary table. Reading from the
--      stream inside a transaction ensures the offset advances only on COMMIT.
--   2. Apply the same cleaning rules as the full Silver load, but only on the
--      stream rows (not the entire Bronze table).
--   3. Merge valid rows into CLEAN_READINGS; insert rejections into REJECTED_RECORDS.
-- =============================================================================
DECLARE
    v_run_id    VARCHAR;
    v_hr_min    NUMBER;
    v_hr_max    NUMBER;
    v_gl_min    NUMBER;
    v_gl_max    NUMBER;
    v_os_min    NUMBER;
    v_os_max    NUMBER;
BEGIN
    -- Generate a unique run ID for this task execution
    v_run_id := UUID_STRING();

    -- Load current thresholds
    SELECT MIN_VALID INTO :v_hr_min FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'    AND IS_CURRENT = TRUE;
    SELECT MAX_VALID INTO :v_hr_max FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'HEART_RATE'    AND IS_CURRENT = TRUE;
    SELECT MIN_VALID INTO :v_gl_min FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE;
    SELECT MAX_VALID INTO :v_gl_max FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'GLUCOSE_LEVEL' AND IS_CURRENT = TRUE;
    SELECT MIN_VALID INTO :v_os_min FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'OXYGEN_SAT'    AND IS_CURRENT = TRUE;
    SELECT MAX_VALID INTO :v_os_max FROM CONTROL.QUALITY_THRESHOLDS WHERE METRIC_NAME = 'OXYGEN_SAT'    AND IS_CURRENT = TRUE;

    -- Log pipeline start
    INSERT INTO CONTROL.PIPELINE_RUN_LOG
        (RUN_ID, PIPELINE_NAME, LAYER, STATUS, STARTED_AT)
    VALUES (:v_run_id, 'SILVER_INCREMENTAL_TASK', 'SILVER', 'STARTED', CURRENT_TIMESTAMP());

    -- Capture new rows from the stream into a temporary table.
    -- Reading from the stream here begins the consumption transaction.
    CREATE OR REPLACE TEMPORARY TABLE TEMP_NEW_READINGS AS
    SELECT * FROM BRONZE.READINGS_STREAM;

    -- Insert rejection records for invalid new rows
    INSERT INTO CONTROL.REJECTED_RECORDS
        (PIPELINE_RUN_ID, SOURCE_TABLE, READING_ID, PATIENT_ID, DEVICE_ID,
         REJECTION_REASON, RAW_ROW_SNAPSHOT, REJECTED_AT)
    WITH CAST_NEW AS (
        SELECT
            t.READING_ID, t.PATIENT_ID, t.DEVICE_ID,
            t.READING_TIMESTAMP AS RAW_TS, t.HEART_RATE AS RAW_HR,
            t.GLUCOSE_LEVEL AS RAW_GL, t.OXYGEN_SATURATION AS RAW_OS,
            TRY_TO_TIMESTAMP(t.READING_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS CAST_TS,
            TRY_TO_NUMBER(t.HEART_RATE)       AS CAST_HR,
            TRY_TO_NUMBER(t.GLUCOSE_LEVEL)    AS CAST_GL,
            TRY_TO_NUMBER(t.OXYGEN_SATURATION) AS CAST_OS,
            t._INGESTION_TIMESTAMP
        FROM TEMP_NEW_READINGS t
    ),
    DEDUPED_NEW AS (
        SELECT c.*,
            ROW_NUMBER() OVER (
                PARTITION BY c.READING_ID
                ORDER BY c.CAST_TS ASC NULLS LAST, c._INGESTION_TIMESTAMP ASC
            ) AS DUP_RANK
        FROM CAST_NEW c
    ),
    EVALUATED_NEW AS (
        SELECT d.*,
            CASE
                WHEN d.READING_ID IS NULL OR TRIM(d.READING_ID) = '' THEN 'MISSING_READING_ID'
                WHEN d.PATIENT_ID IS NULL OR TRIM(d.PATIENT_ID) = '' THEN 'MISSING_PATIENT_ID'
                WHEN d.DEVICE_ID  IS NULL OR TRIM(d.DEVICE_ID)  = '' THEN 'MISSING_DEVICE_ID'
                WHEN d.CAST_TS IS NULL     THEN 'INVALID_TIMESTAMP'
                WHEN d.CAST_HR IS NULL     THEN 'INVALID_HEART_RATE'
                WHEN d.CAST_GL IS NULL     THEN 'INVALID_GLUCOSE'
                WHEN d.CAST_OS IS NULL     THEN 'INVALID_OXYGEN_SAT'
                WHEN NOT EXISTS (SELECT 1 FROM SILVER.CLEAN_PATIENTS cp WHERE cp.PATIENT_ID = d.PATIENT_ID)
                    THEN 'UNKNOWN_PATIENT_ID'
                WHEN NOT EXISTS (SELECT 1 FROM SILVER.CLEAN_DEVICES  cd WHERE cd.DEVICE_ID  = d.DEVICE_ID)
                    THEN 'UNKNOWN_DEVICE_ID'
                WHEN d.CAST_HR < :v_hr_min OR d.CAST_HR > :v_hr_max THEN 'HEART_RATE_OUT_OF_RANGE'
                WHEN d.CAST_GL < :v_gl_min OR d.CAST_GL > :v_gl_max THEN 'GLUCOSE_OUT_OF_RANGE'
                WHEN d.CAST_OS < :v_os_min OR d.CAST_OS > :v_os_max THEN 'OXYGEN_SAT_OUT_OF_RANGE'
                -- Check against ALREADY-LOADED clean readings (cross-batch dedup)
                WHEN EXISTS (SELECT 1 FROM SILVER.CLEAN_READINGS cr WHERE cr.READING_ID = d.READING_ID)
                    AND d.DUP_RANK > 1                                  THEN 'DUPLICATE_READING_ID'
                WHEN d.DUP_RANK > 1                                     THEN 'DUPLICATE_READING_ID'
                ELSE NULL
            END AS REJECTION_REASON
        FROM DEDUPED_NEW d
    )
    SELECT :v_run_id, 'BRONZE.RAW_READINGS',
           e.READING_ID, e.PATIENT_ID, e.DEVICE_ID,
           e.REJECTION_REASON,
           'reading_id='  || COALESCE(e.READING_ID,'NULL')
             || '|patient_id='  || COALESCE(e.PATIENT_ID,'NULL')
             || '|ts='          || COALESCE(e.RAW_TS,'NULL')
             || '|hr='          || COALESCE(e.RAW_HR,'NULL'),
           CURRENT_TIMESTAMP()
    FROM EVALUATED_NEW e
    WHERE e.REJECTION_REASON IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM CONTROL.REJECTED_RECORDS rr
          WHERE rr.READING_ID = e.READING_ID AND rr.REJECTION_REASON = e.REJECTION_REASON
      );

    -- Merge valid new rows into Silver
    MERGE INTO SILVER.CLEAN_READINGS AS target
    USING (
        WITH CAST_NEW AS (
            SELECT t.READING_ID, t.PATIENT_ID, t.DEVICE_ID,
                TRY_TO_TIMESTAMP(t.READING_TIMESTAMP, 'YYYY-MM-DD HH24:MI:SS') AS CAST_TS,
                TRY_TO_NUMBER(t.HEART_RATE)        AS CAST_HR,
                TRY_TO_NUMBER(t.GLUCOSE_LEVEL)     AS CAST_GL,
                TRY_TO_NUMBER(t.OXYGEN_SATURATION) AS CAST_OS,
                t._SOURCE_FILE, t._INGESTION_TIMESTAMP
            FROM TEMP_NEW_READINGS t
        ),
        DEDUPED_NEW AS (
            SELECT c.*,
                ROW_NUMBER() OVER (
                    PARTITION BY c.READING_ID
                    ORDER BY c.CAST_TS ASC NULLS LAST, c._INGESTION_TIMESTAMP ASC
                ) AS DUP_RANK
            FROM CAST_NEW c
        )
        SELECT d.READING_ID, d.PATIENT_ID, d.DEVICE_ID,
               d.CAST_TS, d.CAST_TS::DATE AS READING_DATE,
               d.CAST_HR, d.CAST_GL, d.CAST_OS,
               d._SOURCE_FILE, d._INGESTION_TIMESTAMP
        FROM DEDUPED_NEW d
        WHERE d.DUP_RANK = 1
          AND d.READING_ID IS NOT NULL AND TRIM(d.READING_ID) != ''
          AND d.PATIENT_ID IS NOT NULL AND TRIM(d.PATIENT_ID) != ''
          AND d.DEVICE_ID  IS NOT NULL AND TRIM(d.DEVICE_ID)  != ''
          AND d.CAST_TS IS NOT NULL AND d.CAST_HR IS NOT NULL
          AND d.CAST_GL IS NOT NULL AND d.CAST_OS IS NOT NULL
          AND EXISTS (SELECT 1 FROM SILVER.CLEAN_PATIENTS cp WHERE cp.PATIENT_ID = d.PATIENT_ID)
          AND EXISTS (SELECT 1 FROM SILVER.CLEAN_DEVICES  cd WHERE cd.DEVICE_ID  = d.DEVICE_ID)
          AND d.CAST_HR BETWEEN :v_hr_min AND :v_hr_max
          AND d.CAST_GL BETWEEN :v_gl_min AND :v_gl_max
          AND d.CAST_OS BETWEEN :v_os_min AND :v_os_max
          -- Exclude reading_ids already in Silver (prevents cross-batch duplicates)
          AND NOT EXISTS (SELECT 1 FROM SILVER.CLEAN_READINGS cr WHERE cr.READING_ID = d.READING_ID)
    ) AS source
    ON target.READING_ID = source.READING_ID
    WHEN NOT MATCHED THEN INSERT (
        READING_ID, PATIENT_ID, READING_TIMESTAMP, READING_DATE,
        HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SATURATION, DEVICE_ID,
        _SOURCE_FILE, _BRONZE_INGESTED_AT, _SILVER_LOADED_AT
    ) VALUES (
        source.READING_ID, source.PATIENT_ID, source.CAST_TS, source.READING_DATE,
        source.CAST_HR, source.CAST_GL, source.CAST_OS, source.DEVICE_ID,
        source._SOURCE_FILE, source._INGESTION_TIMESTAMP, CURRENT_TIMESTAMP()
    );

    -- Update pipeline log with completion status
    UPDATE CONTROL.PIPELINE_RUN_LOG
    SET STATUS = 'COMPLETED', COMPLETED_AT = CURRENT_TIMESTAMP(),
        ROWS_INPUT    = (SELECT COUNT(*) FROM TEMP_NEW_READINGS),
        ROWS_ACCEPTED = (SELECT COUNT(*) FROM SILVER.CLEAN_READINGS),
        ROWS_REJECTED = (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS WHERE PIPELINE_RUN_ID = :v_run_id)
    WHERE RUN_ID = :v_run_id;

    RETURN 'Silver incremental load complete. Run ID: ' || :v_run_id;
END;


-- =============================================================================
-- TASK 2: GOLD_REFRESH_TASK (Child of SILVER_INCREMENTAL_TASK)
--
-- Purpose  : Refreshes all three Gold tables after Silver is updated.
-- Strategy : For DAILY_PATIENT_SUMMARY and PATIENT_TRENDS, identifies the
--            earliest affected date (minimum READING_DATE among newly added
--            Silver rows added after the task start) and rebuilds Gold rows
--            from that date forward. This handles late-arriving records.
--            For READING_ALERTS, a full MERGE re-evaluates all Silver readings.
-- =============================================================================
CREATE OR REPLACE TASK HEALTHCARE_MONITORING_DB.PUBLIC.GOLD_REFRESH_TASK
    WAREHOUSE  = COMPUTE_WH
    AFTER HEALTHCARE_MONITORING_DB.PUBLIC.SILVER_INCREMENTAL_TASK
    COMMENT    = 'Child task. Refreshes Gold tables after Silver incremental load succeeds.'
AS
BEGIN
    -- Determine the earliest date affected by new Silver rows
    -- (rows with _SILVER_LOADED_AT in the last 30 minutes, conservative window)
    LET v_min_date DATE := (
        SELECT MIN(READING_DATE)
        FROM SILVER.CLEAN_READINGS
        WHERE _SILVER_LOADED_AT >= DATEADD('minute', -30, CURRENT_TIMESTAMP())
    );

    -- If no new Silver rows exist (shouldn't happen given WHEN clause, but be safe)
    IF (v_min_date IS NULL) THEN
        RETURN 'No new Silver rows found. Gold refresh skipped.';
    END IF;

    -- Refresh DAILY_PATIENT_SUMMARY for affected dates
    DELETE FROM GOLD.DAILY_PATIENT_SUMMARY
    WHERE READING_DATE >= :v_min_date;

    INSERT INTO GOLD.DAILY_PATIENT_SUMMARY
        (PATIENT_ID, READING_DATE, TOTAL_READINGS,
         AVG_HEART_RATE, MIN_HEART_RATE, MAX_HEART_RATE,
         AVG_GLUCOSE_LEVEL, MIN_GLUCOSE_LEVEL, MAX_GLUCOSE_LEVEL,
         AVG_OXYGEN_SAT, MIN_OXYGEN_SAT, MAX_OXYGEN_SAT,
         HIGH_HR_READINGS, LOW_OXYGEN_READINGS, HIGH_GLUCOSE_READINGS,
         SUMMARY_CREATED_AT)
    SELECT
        cr.PATIENT_ID,
        cr.READING_DATE,
        COUNT(*),
        ROUND(AVG(cr.HEART_RATE),2),    MIN(cr.HEART_RATE),    MAX(cr.HEART_RATE),
        ROUND(AVG(cr.GLUCOSE_LEVEL),2), MIN(cr.GLUCOSE_LEVEL), MAX(cr.GLUCOSE_LEVEL),
        ROUND(AVG(cr.OXYGEN_SATURATION),2), MIN(cr.OXYGEN_SATURATION), MAX(cr.OXYGEN_SATURATION),
        SUM(CASE WHEN cr.HEART_RATE > 160      THEN 1 ELSE 0 END),
        SUM(CASE WHEN cr.OXYGEN_SATURATION < 92 THEN 1 ELSE 0 END),
        SUM(CASE WHEN cr.GLUCOSE_LEVEL > 400   THEN 1 ELSE 0 END),
        CURRENT_TIMESTAMP()
    FROM SILVER.CLEAN_READINGS cr
    WHERE cr.READING_DATE >= :v_min_date
    GROUP BY cr.PATIENT_ID, cr.READING_DATE;

    -- Refresh PATIENT_TRENDS for affected dates
    DELETE FROM GOLD.PATIENT_TRENDS WHERE READING_DATE >= :v_min_date;

    INSERT INTO GOLD.PATIENT_TRENDS
        (PATIENT_ID, READING_DATE,
         AVG_HEART_RATE, AVG_GLUCOSE_LEVEL, AVG_OXYGEN_SAT,
         PREV_AVG_HEART_RATE, PREV_AVG_GLUCOSE_LEVEL, PREV_AVG_OXYGEN_SAT,
         DELTA_HEART_RATE, DELTA_GLUCOSE_LEVEL, DELTA_OXYGEN_SAT,
         TREND_CREATED_AT)
    WITH DAILY_AVGS AS (
        SELECT PATIENT_ID, READING_DATE,
            ROUND(AVG(HEART_RATE),2)       AS AVG_HR,
            ROUND(AVG(GLUCOSE_LEVEL),2)    AS AVG_GL,
            ROUND(AVG(OXYGEN_SATURATION),2) AS AVG_OS
        FROM SILVER.CLEAN_READINGS
        GROUP BY PATIENT_ID, READING_DATE
    ),
    WITH_LAG AS (
        SELECT *,
            LAG(AVG_HR, 1) OVER (PARTITION BY PATIENT_ID ORDER BY READING_DATE) AS PREV_HR,
            LAG(AVG_GL, 1) OVER (PARTITION BY PATIENT_ID ORDER BY READING_DATE) AS PREV_GL,
            LAG(AVG_OS, 1) OVER (PARTITION BY PATIENT_ID ORDER BY READING_DATE) AS PREV_OS
        FROM DAILY_AVGS
    )
    SELECT PATIENT_ID, READING_DATE,
           AVG_HR, AVG_GL, AVG_OS,
           PREV_HR, PREV_GL, PREV_OS,
           ROUND(AVG_HR - PREV_HR, 2),
           ROUND(AVG_GL - PREV_GL, 2),
           ROUND(AVG_OS - PREV_OS, 2),
           CURRENT_TIMESTAMP()
    FROM WITH_LAG
    WHERE READING_DATE >= :v_min_date;

    -- Refresh READING_ALERTS (full MERGE — alerts may change as Silver changes)
    MERGE INTO GOLD.READING_ALERTS AS target
    USING (
        SELECT cr.READING_ID, cr.PATIENT_ID, cr.READING_TIMESTAMP,
               'HEART_RATE' AS METRIC_NAME, cr.HEART_RATE AS OBSERVED_VALUE,
               CASE WHEN cr.HEART_RATE > 160 THEN 'HEART_RATE > 160'
                    ELSE 'HEART_RATE > 100' END AS THRESHOLD_TRIGGERED,
               CASE WHEN cr.HEART_RATE > 160 THEN 'VERY_HIGH' ELSE 'ELEVATED' END AS ALERT_CATEGORY
        FROM SILVER.CLEAN_READINGS cr WHERE cr.HEART_RATE > 100
        UNION ALL
        SELECT cr.READING_ID, cr.PATIENT_ID, cr.READING_TIMESTAMP,
               'GLUCOSE_LEVEL', cr.GLUCOSE_LEVEL,
               CASE WHEN cr.GLUCOSE_LEVEL > 400 THEN 'GLUCOSE_LEVEL > 400'
                    ELSE 'GLUCOSE_LEVEL > 180' END,
               CASE WHEN cr.GLUCOSE_LEVEL > 400 THEN 'VERY_HIGH' ELSE 'ELEVATED' END
        FROM SILVER.CLEAN_READINGS cr WHERE cr.GLUCOSE_LEVEL > 180
        UNION ALL
        SELECT cr.READING_ID, cr.PATIENT_ID, cr.READING_TIMESTAMP,
               'OXYGEN_SAT', cr.OXYGEN_SATURATION, 'OXYGEN_SAT < 92', 'LOW'
        FROM SILVER.CLEAN_READINGS cr WHERE cr.OXYGEN_SATURATION < 92
    ) AS source
    ON target.READING_ID = source.READING_ID AND target.METRIC_NAME = source.METRIC_NAME
    WHEN NOT MATCHED THEN INSERT (
        READING_ID, PATIENT_ID, READING_TIMESTAMP, METRIC_NAME,
        OBSERVED_VALUE, THRESHOLD_TRIGGERED, ALERT_CATEGORY, PROCESSED_AT
    ) VALUES (
        source.READING_ID, source.PATIENT_ID, source.READING_TIMESTAMP, source.METRIC_NAME,
        source.OBSERVED_VALUE, source.THRESHOLD_TRIGGERED, source.ALERT_CATEGORY, CURRENT_TIMESTAMP()
    );

    RETURN 'Gold refresh complete for dates >= ' || :v_min_date::VARCHAR;
END;


-- =============================================================================
-- TASK 3: PIPELINE_LOG_TASK (Child of GOLD_REFRESH_TASK)
--
-- Purpose : Records the overall pipeline completion in PIPELINE_RUN_LOG.
-- =============================================================================
CREATE OR REPLACE TASK HEALTHCARE_MONITORING_DB.PUBLIC.PIPELINE_LOG_TASK
    WAREHOUSE  = COMPUTE_WH
    AFTER HEALTHCARE_MONITORING_DB.PUBLIC.GOLD_REFRESH_TASK
    COMMENT    = 'Child task. Logs end-to-end pipeline completion after Gold refresh.'
AS
    INSERT INTO CONTROL.PIPELINE_RUN_LOG
        (RUN_ID, PIPELINE_NAME, LAYER, STATUS, STARTED_AT, COMPLETED_AT,
         ROWS_INSERTED)
    VALUES (
        UUID_STRING(),
        'PIPELINE_LOG_TASK',
        'GOLD',
        'COMPLETED',
        CURRENT_TIMESTAMP(),
        CURRENT_TIMESTAMP(),
        (SELECT COUNT(*) FROM GOLD.DAILY_PATIENT_SUMMARY)
    );


-- =============================================================================
-- ACTIVATION COMMANDS
-- Run these in bottom-up order (children first, then root).
-- Tasks are SUSPENDED by default — they will not run until RESUMED.
-- =============================================================================
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.PIPELINE_LOG_TASK     RESUME;
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.GOLD_REFRESH_TASK     RESUME;
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.SILVER_INCREMENTAL_TASK RESUME;

-- Verify task state:
SHOW TASKS IN DATABASE HEALTHCARE_MONITORING_DB;
-- All three tasks should show STATE = 'started'


-- =============================================================================
-- SUSPEND COMMANDS (use when pipeline maintenance is needed)
-- =============================================================================
-- ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.SILVER_INCREMENTAL_TASK SUSPEND;
-- ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.GOLD_REFRESH_TASK     SUSPEND;
-- ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.PIPELINE_LOG_TASK     SUSPEND;


-- =============================================================================
-- MONITORING QUERIES
-- =============================================================================

-- View recent task execution history (last 24 hours):
SELECT
    NAME,
    STATE,
    SCHEDULED_TIME,
    QUERY_START_TIME,
    COMPLETED_TIME,
    RETURN_VALUE,
    ERROR_CODE,
    ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 20
))
ORDER BY SCHEDULED_TIME DESC;

-- Check if stream has unconsumed data:
SELECT SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM') AS STREAM_HAS_DATA;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
