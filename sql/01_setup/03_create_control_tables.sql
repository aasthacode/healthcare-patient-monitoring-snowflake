-- =============================================================================
-- File        : 03_create_control_tables.sql
-- Layer       : Setup — CONTROL schema
-- Description : Creates the four control/monitoring tables:
--                 1. CONTROL.REJECTED_RECORDS
--                 2. CONTROL.PIPELINE_RUN_LOG
--                 3. CONTROL.DATA_QUALITY_LOG
--                 4. CONTROL.QUALITY_THRESHOLDS
--               Also seeds QUALITY_THRESHOLDS with initial illustrative values.
-- Run order   : 3 — run after 01 and 02.
-- Idempotent  : Yes — uses CREATE TABLE IF NOT EXISTS.
--               QUALITY_THRESHOLDS seed uses MERGE to avoid duplicates on rerun.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;
USE SCHEMA CONTROL;


-- =============================================================================
-- TABLE 1: PIPELINE_RUN_LOG
-- Purpose : One row per pipeline execution (Bronze load, Silver transform, etc.)
--           Provides a top-level audit trail of every time the pipeline ran.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONTROL.PIPELINE_RUN_LOG (
    RUN_ID          VARCHAR(36)   NOT NULL         COMMENT 'UUID generated at runtime via UUID_STRING().',
    PIPELINE_NAME   VARCHAR(100)  NOT NULL         COMMENT 'Logical name of the pipeline step, e.g. BRONZE_LOAD_PATIENTS.',
    LAYER           VARCHAR(20)   NOT NULL         COMMENT 'Medallion layer: BRONZE, SILVER, GOLD, or CONTROL.',
    STATUS          VARCHAR(20)   NOT NULL         COMMENT 'STARTED, COMPLETED, or FAILED.',
    STARTED_AT      TIMESTAMP_NTZ NOT NULL         COMMENT 'Timestamp when the run began.',
    COMPLETED_AT    TIMESTAMP_NTZ                  COMMENT 'Timestamp when the run finished. NULL if still running or failed before completion.',
    SOURCE_FILE     VARCHAR(500)                   COMMENT 'Source filename where relevant.',
    ROWS_INPUT      NUMBER(18, 0)                  COMMENT 'Number of rows read from the source.',
    ROWS_ACCEPTED   NUMBER(18, 0)                  COMMENT 'Number of rows that passed all quality checks.',
    ROWS_REJECTED   NUMBER(18, 0)                  COMMENT 'Number of rows that failed at least one check.',
    ROWS_INSERTED   NUMBER(18, 0)                  COMMENT 'Number of rows actually inserted into the target table.',
    ERROR_MESSAGE   VARCHAR(4000)                  COMMENT 'NULL on success; error text on failure.',
    CONSTRAINT PK_PIPELINE_RUN_LOG PRIMARY KEY (RUN_ID)
)
COMMENT = 'Audit log of every pipeline execution. One row per run per step.';


-- =============================================================================
-- TABLE 2: REJECTED_RECORDS
-- Purpose : Preserves every record rejected during Silver cleaning with its
--           rejection reason. Append-only — records are never updated.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONTROL.REJECTED_RECORDS (
    REJECTION_ID        NUMBER AUTOINCREMENT  NOT NULL COMMENT 'Auto-incrementing surrogate key.',
    PIPELINE_RUN_ID     VARCHAR(36)           NOT NULL COMMENT 'Foreign key to PIPELINE_RUN_LOG.RUN_ID.',
    SOURCE_TABLE        VARCHAR(200)          NOT NULL COMMENT 'Fully qualified Bronze table the record came from.',
    READING_ID          VARCHAR(50)                    COMMENT 'Original reading_id value (may be NULL if field was missing).',
    PATIENT_ID          VARCHAR(50)                    COMMENT 'Original patient_id value (may be NULL if field was missing).',
    DEVICE_ID           VARCHAR(50)                    COMMENT 'Original device_id value (may be NULL if field was missing).',
    REJECTION_REASON    VARCHAR(100)          NOT NULL COMMENT 'Rule reason code. See docs/transformation_rules.md for full list.',
    RAW_ROW_SNAPSHOT    VARCHAR(4000)                  COMMENT 'Comma-separated snapshot of the rejected row key columns at the time of rejection.',
    REJECTED_AT         TIMESTAMP_NTZ         NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'Timestamp when this rejection was recorded.',
    CONSTRAINT PK_REJECTED_RECORDS PRIMARY KEY (REJECTION_ID)
)
COMMENT = 'Rejected records from Silver cleaning. Append-only audit trail. Never silently discard invalid data.';


-- =============================================================================
-- TABLE 3: DATA_QUALITY_LOG
-- Purpose : One row per individual data quality check result per pipeline run.
--           Lets you query "did this specific check pass or fail on this run?"
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONTROL.DATA_QUALITY_LOG (
    LOG_ID          NUMBER AUTOINCREMENT  NOT NULL COMMENT 'Auto-incrementing surrogate key.',
    RUN_ID          VARCHAR(36)           NOT NULL COMMENT 'Foreign key to PIPELINE_RUN_LOG.RUN_ID.',
    CHECK_NAME      VARCHAR(200)          NOT NULL COMMENT 'Short identifier for the check, e.g. DUPLICATE_READING_IDS.',
    LAYER           VARCHAR(20)           NOT NULL COMMENT 'Layer where the check ran: BRONZE, SILVER, GOLD.',
    TABLE_NAME      VARCHAR(200)          NOT NULL COMMENT 'Fully qualified table name checked.',
    CHECK_RESULT    VARCHAR(10)           NOT NULL COMMENT 'PASSED or FAILED.',
    ROW_COUNT       NUMBER(18, 0)                  COMMENT 'Number of rows that triggered or were evaluated by this check.',
    CHECKED_AT      TIMESTAMP_NTZ         NOT NULL DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this check ran.',
    NOTES           VARCHAR(2000)                  COMMENT 'Additional context about the check result.',
    CONSTRAINT PK_DATA_QUALITY_LOG PRIMARY KEY (LOG_ID)
)
COMMENT = 'Individual data quality check results per pipeline run. Query to see which checks pass/fail over time.';


-- =============================================================================
-- TABLE 4: QUALITY_THRESHOLDS
-- Purpose : Configurable plausibility ranges for numeric measurements.
--           Silver and Gold SQL read from this table rather than hard-coding
--           limits. Update rows here to change thresholds without rewriting SQL.
--
-- DISCLAIMER: These values are ILLUSTRATIVE EXAMPLES only.
--             They are NOT clinically validated medical thresholds.
-- =============================================================================
CREATE TABLE IF NOT EXISTS CONTROL.QUALITY_THRESHOLDS (
    THRESHOLD_ID    NUMBER AUTOINCREMENT  NOT NULL COMMENT 'Auto-incrementing surrogate key.',
    METRIC_NAME     VARCHAR(50)           NOT NULL COMMENT 'Metric identifier: HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SAT.',
    MIN_VALID       NUMBER(10, 2)         NOT NULL COMMENT 'Minimum value for a reading to be accepted in Silver. Below this = rejected.',
    MAX_VALID       NUMBER(10, 2)         NOT NULL COMMENT 'Maximum value for a reading to be accepted in Silver. Above this = rejected.',
    ALERT_MIN       NUMBER(10, 2)                  COMMENT 'Threshold below which a Gold alert is generated (NULL = no lower alert).',
    ALERT_MAX       NUMBER(10, 2)                  COMMENT 'Threshold above which a Gold alert is generated (NULL = no upper alert).',
    EFFECTIVE_FROM  DATE                  NOT NULL DEFAULT CURRENT_DATE() COMMENT 'Date from which this threshold row is active.',
    IS_CURRENT      BOOLEAN               NOT NULL DEFAULT TRUE COMMENT 'TRUE for the currently active row per metric.',
    NOTES           VARCHAR(500)                   COMMENT 'Documentation note about this threshold.',
    CONSTRAINT PK_QUALITY_THRESHOLDS PRIMARY KEY (THRESHOLD_ID)
)
COMMENT = 'Configurable plausibility thresholds. ILLUSTRATIVE VALUES ONLY — not clinically validated.';


-- =============================================================================
-- SEED: Insert initial threshold values.
-- Uses MERGE to avoid duplicate seed rows if this script is re-run.
-- =============================================================================
MERGE INTO CONTROL.QUALITY_THRESHOLDS AS target
USING (
    SELECT * FROM (VALUES
        -- metric_name,    min_valid, max_valid, alert_min, alert_max,  notes
        ('HEART_RATE',      40,        180,       100,       160,
         'Illustrative bpm range. Below 40 or above 180 = invalid. Alert: >100 elevated, >160 very high. NOT clinically validated.'),
        ('GLUCOSE_LEVEL',   50,        600,       180,       400,
         'Illustrative mg/dL range. Below 50 or above 600 = invalid. Alert: >180 elevated, >400 very high. NOT clinically validated.'),
        ('OXYGEN_SAT',      85,        100,       NULL,      NULL,
         'Illustrative SpO2 %. Below 85 or above 100 = invalid. Alert generated for values below 92. NOT clinically validated.')
    ) AS v (METRIC_NAME, MIN_VALID, MAX_VALID, ALERT_MIN, ALERT_MAX, NOTES)
) AS source
    ON target.METRIC_NAME = source.METRIC_NAME AND target.IS_CURRENT = TRUE
WHEN NOT MATCHED THEN
    INSERT (METRIC_NAME, MIN_VALID, MAX_VALID, ALERT_MIN, ALERT_MAX, IS_CURRENT, NOTES)
    VALUES (source.METRIC_NAME, source.MIN_VALID, source.MAX_VALID,
            source.ALERT_MIN, source.ALERT_MAX, TRUE, source.NOTES);

-- Note: Oxygen saturation alert is for values BELOW a minimum.
-- The GOLD.READING_ALERTS logic uses a separate check:
--   oxygen_saturation < 92 => alert 'LOW_OXYGEN_SAT'
-- This is handled in the Gold layer SQL with a CASE expression.


-- =============================================================================
-- VALIDATION QUERIES
-- Run these after the script to confirm tables and seed data are correct.
-- =============================================================================
SHOW TABLES IN SCHEMA CONTROL;

-- Expected: 4 tables — PIPELINE_RUN_LOG, REJECTED_RECORDS, DATA_QUALITY_LOG, QUALITY_THRESHOLDS

SELECT METRIC_NAME, MIN_VALID, MAX_VALID, ALERT_MIN, ALERT_MAX, IS_CURRENT
FROM CONTROL.QUALITY_THRESHOLDS
ORDER BY METRIC_NAME;

-- Expected: 3 rows (GLUCOSE_LEVEL, HEART_RATE, OXYGEN_SAT), all IS_CURRENT = TRUE

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
