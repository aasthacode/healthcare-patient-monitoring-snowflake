-- =============================================================================
-- File        : 01_create_gold_tables.sql
-- Layer       : Gold
-- Description : Creates the three analytics-ready tables in the GOLD schema.
--               These tables are populated by the subsequent Gold load scripts.
-- Run order   : 10 — run after all Silver scripts.
-- Idempotent  : Yes — uses CREATE TABLE IF NOT EXISTS.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;


-- =============================================================================
-- TABLE: GOLD.DAILY_PATIENT_SUMMARY
-- Purpose : One row per patient per calendar day. Aggregates all valid readings
--           from SILVER.CLEAN_READINGS grouped by patient and date.
--           Used to answer: "What are each patient's daily averages?"
-- =============================================================================
CREATE TABLE IF NOT EXISTS GOLD.DAILY_PATIENT_SUMMARY (
    SUMMARY_ID              NUMBER AUTOINCREMENT  NOT NULL  COMMENT 'Surrogate key.',
    PATIENT_ID              VARCHAR(50)           NOT NULL  COMMENT 'FK to SILVER.CLEAN_PATIENTS.',
    READING_DATE            DATE                  NOT NULL  COMMENT 'Calendar date of the readings aggregated here.',
    TOTAL_READINGS          NUMBER(6,0)           NOT NULL  COMMENT 'Count of valid readings for this patient on this day.',
    AVG_HEART_RATE          NUMBER(8,2)                    COMMENT 'Average heart rate (bpm) for the day.',
    MIN_HEART_RATE          NUMBER(8,2)                    COMMENT 'Minimum heart rate for the day.',
    MAX_HEART_RATE          NUMBER(8,2)                    COMMENT 'Maximum heart rate for the day.',
    AVG_GLUCOSE_LEVEL       NUMBER(10,2)                   COMMENT 'Average blood glucose (mg/dL) for the day.',
    MIN_GLUCOSE_LEVEL       NUMBER(10,2)                   COMMENT 'Minimum blood glucose for the day.',
    MAX_GLUCOSE_LEVEL       NUMBER(10,2)                   COMMENT 'Maximum blood glucose for the day.',
    AVG_OXYGEN_SAT          NUMBER(6,2)                    COMMENT 'Average SpO2 (%) for the day.',
    MIN_OXYGEN_SAT          NUMBER(6,2)                    COMMENT 'Minimum SpO2 for the day.',
    MAX_OXYGEN_SAT          NUMBER(6,2)                    COMMENT 'Maximum SpO2 for the day.',
    -- Counts of readings that breached example alert thresholds (illustrative only)
    HIGH_HR_READINGS        NUMBER(6,0)           DEFAULT 0 COMMENT 'Count of readings with heart_rate above the ALERT_MAX threshold. Illustrative flag only.',
    LOW_OXYGEN_READINGS     NUMBER(6,0)           DEFAULT 0 COMMENT 'Count of readings with oxygen_saturation below 92. Illustrative flag only.',
    HIGH_GLUCOSE_READINGS   NUMBER(6,0)           DEFAULT 0 COMMENT 'Count of readings with glucose_level above the ALERT_MAX threshold. Illustrative flag only.',
    SUMMARY_CREATED_AT      TIMESTAMP_NTZ         DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this summary row was inserted/last refreshed.',
    CONSTRAINT PK_DAILY_PATIENT_SUMMARY PRIMARY KEY (SUMMARY_ID),
    CONSTRAINT UQ_DAILY_PATIENT_SUMMARY UNIQUE (PATIENT_ID, READING_DATE)
)
COMMENT = 'Gold aggregation table. One row per patient per day. Derived from SILVER.CLEAN_READINGS. Illustrative analytics only — not clinical output.';


-- =============================================================================
-- TABLE: GOLD.READING_ALERTS
-- Purpose : Flags individual readings that cross configurable example thresholds.
--           One row per reading per triggered rule.
--           A reading may appear multiple times if it triggers more than one rule
--           (e.g., both high heart rate AND high glucose).
--           FOR DEMONSTRATION ONLY — not medical diagnoses.
-- =============================================================================
CREATE TABLE IF NOT EXISTS GOLD.READING_ALERTS (
    ALERT_ID            NUMBER AUTOINCREMENT  NOT NULL  COMMENT 'Surrogate key.',
    READING_ID          VARCHAR(50)           NOT NULL  COMMENT 'FK to SILVER.CLEAN_READINGS.',
    PATIENT_ID          VARCHAR(50)           NOT NULL  COMMENT 'FK to SILVER.CLEAN_PATIENTS.',
    READING_TIMESTAMP   TIMESTAMP_NTZ         NOT NULL  COMMENT 'Timestamp of the flagged reading.',
    METRIC_NAME         VARCHAR(50)           NOT NULL  COMMENT 'Which metric triggered the alert: HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SAT.',
    OBSERVED_VALUE      NUMBER(10,2)          NOT NULL  COMMENT 'The actual measured value.',
    THRESHOLD_TRIGGERED VARCHAR(200)          NOT NULL  COMMENT 'Description of the rule, e.g. HEART_RATE > 160.',
    ALERT_CATEGORY      VARCHAR(50)           NOT NULL  COMMENT 'Severity category: ELEVATED or VERY_HIGH for high alerts, LOW for low oxygen.',
    PROCESSED_AT        TIMESTAMP_NTZ         DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this alert row was generated.',
    CONSTRAINT PK_READING_ALERTS PRIMARY KEY (ALERT_ID),
    CONSTRAINT UQ_READING_ALERTS UNIQUE (READING_ID, METRIC_NAME)
)
COMMENT = 'Gold alert flags. Readings that crossed illustrative example thresholds. FOR DEMONSTRATION ONLY — not clinical diagnoses.';


-- =============================================================================
-- TABLE: GOLD.PATIENT_TRENDS
-- Purpose : Day-over-day comparison of patient metrics using the LAG window
--           function. Produces one row per patient per day, showing the current
--           day average alongside the previous day average and the difference.
--           Used to answer: "How do readings change from one day to the next?"
-- =============================================================================
CREATE TABLE IF NOT EXISTS GOLD.PATIENT_TRENDS (
    TREND_ID                NUMBER AUTOINCREMENT  NOT NULL  COMMENT 'Surrogate key.',
    PATIENT_ID              VARCHAR(50)           NOT NULL  COMMENT 'FK to SILVER.CLEAN_PATIENTS.',
    READING_DATE            DATE                  NOT NULL  COMMENT 'Current date for this trend row.',

    -- Current day averages
    AVG_HEART_RATE          NUMBER(8,2)                    COMMENT 'Average heart rate on READING_DATE.',
    AVG_GLUCOSE_LEVEL       NUMBER(10,2)                   COMMENT 'Average glucose on READING_DATE.',
    AVG_OXYGEN_SAT          NUMBER(6,2)                    COMMENT 'Average SpO2 on READING_DATE.',

    -- Previous day averages (populated by LAG window function)
    PREV_AVG_HEART_RATE     NUMBER(8,2)                    COMMENT 'Average heart rate on the preceding day with a reading. NULL if no prior day.',
    PREV_AVG_GLUCOSE_LEVEL  NUMBER(10,2)                   COMMENT 'Average glucose on the preceding day. NULL if no prior day.',
    PREV_AVG_OXYGEN_SAT     NUMBER(6,2)                    COMMENT 'Average SpO2 on the preceding day. NULL if no prior day.',

    -- Day-over-day differences (current minus previous)
    DELTA_HEART_RATE        NUMBER(8,2)                    COMMENT 'Change in avg heart rate vs previous day. Positive = increase.',
    DELTA_GLUCOSE_LEVEL     NUMBER(10,2)                   COMMENT 'Change in avg glucose vs previous day.',
    DELTA_OXYGEN_SAT        NUMBER(6,2)                    COMMENT 'Change in avg SpO2 vs previous day.',

    TREND_CREATED_AT        TIMESTAMP_NTZ         DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this row was generated.',
    CONSTRAINT PK_PATIENT_TRENDS PRIMARY KEY (TREND_ID),
    CONSTRAINT UQ_PATIENT_TRENDS UNIQUE (PATIENT_ID, READING_DATE)
)
COMMENT = 'Gold day-over-day trend table. Uses LAG window function to compare daily averages. Derived from SILVER.CLEAN_READINGS.';


-- =============================================================================
-- VALIDATION
-- =============================================================================
SHOW TABLES IN SCHEMA GOLD;
-- Expected: 3 tables — DAILY_PATIENT_SUMMARY, READING_ALERTS, PATIENT_TRENDS

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
