-- =============================================================================
-- File        : 01_create_silver_tables.sql
-- Layer       : Silver
-- Description : Creates the three cleaned tables in the SILVER schema.
--               Unlike Bronze, Silver tables use proper data types (NUMBER,
--               DATE, TIMESTAMP_NTZ) because values have been validated by the
--               time they reach this layer.
-- Run order   : 6 — run after all Bronze scripts.
-- Idempotent  : Yes — uses CREATE TABLE IF NOT EXISTS.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;


-- =============================================================================
-- TABLE: SILVER.CLEAN_PATIENTS
-- =============================================================================
CREATE TABLE IF NOT EXISTS SILVER.CLEAN_PATIENTS (
    PATIENT_ID          VARCHAR(50)       NOT NULL  COMMENT 'Unique patient identifier. Matches source patient_id.',
    AGE                 NUMBER(3,0)       NOT NULL  COMMENT 'Age in years. Cast from VARCHAR; validated 0–120.',
    GENDER              VARCHAR(50)       NOT NULL  COMMENT 'Standardised to INITCAP. Unknown if source was NULL.',
    REGISTRATION_DATE   DATE              NOT NULL  COMMENT 'Cast from VARCHAR using TRY_TO_DATE.',
    CITY                VARCHAR(100)               COMMENT 'City of residence.',

    -- Traceability back to Bronze
    _SOURCE_FILE        VARCHAR(500)               COMMENT 'Source filename from Bronze row.',
    _BRONZE_INGESTED_AT TIMESTAMP_NTZ              COMMENT 'Ingestion timestamp from Bronze row.',
    _SILVER_LOADED_AT   TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
                                                   COMMENT 'Timestamp when this row was inserted or last updated in Silver.',
    CONSTRAINT PK_CLEAN_PATIENTS PRIMARY KEY (PATIENT_ID)
)
COMMENT = 'Cleaned patient records promoted from BRONZE.RAW_PATIENTS. All type casts applied and validated.';


-- =============================================================================
-- TABLE: SILVER.CLEAN_DEVICES
-- =============================================================================
CREATE TABLE IF NOT EXISTS SILVER.CLEAN_DEVICES (
    DEVICE_ID           VARCHAR(50)       NOT NULL  COMMENT 'Unique device identifier.',
    DEVICE_TYPE         VARCHAR(100)      NOT NULL  COMMENT 'Standardised to INITCAP.',
    MANUFACTURER        VARCHAR(200)               COMMENT 'Manufacturer name.',
    DEPLOYMENT_DATE     DATE              NOT NULL  COMMENT 'Cast from VARCHAR using TRY_TO_DATE.',
    DEVICE_STATUS       VARCHAR(50)       NOT NULL  COMMENT 'One of: Active, Maintenance, Retired, Unknown.',

    _SOURCE_FILE        VARCHAR(500)               COMMENT 'Source filename from Bronze row.',
    _BRONZE_INGESTED_AT TIMESTAMP_NTZ              COMMENT 'Ingestion timestamp from Bronze row.',
    _SILVER_LOADED_AT   TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
                                                   COMMENT 'Timestamp when this row was inserted or last updated in Silver.',
    CONSTRAINT PK_CLEAN_DEVICES PRIMARY KEY (DEVICE_ID)
)
COMMENT = 'Cleaned device records promoted from BRONZE.RAW_DEVICES.';


-- =============================================================================
-- TABLE: SILVER.CLEAN_READINGS
--
-- This is the central fact table. It contains only readings that have passed
-- ALL Silver quality checks:
--   - All mandatory fields present and non-null
--   - Timestamps and numeric values successfully cast
--   - patient_id and device_id found in CLEAN_PATIENTS / CLEAN_DEVICES
--   - Numeric values within configured plausibility ranges
--   - Deduplicated by reading_id (earliest timestamp retained)
-- =============================================================================
CREATE TABLE IF NOT EXISTS SILVER.CLEAN_READINGS (
    READING_ID          VARCHAR(50)       NOT NULL  COMMENT 'Unique reading identifier. Deduplicated from Bronze.',
    PATIENT_ID          VARCHAR(50)       NOT NULL  COMMENT 'Validated FK to SILVER.CLEAN_PATIENTS.',
    READING_TIMESTAMP   TIMESTAMP_NTZ     NOT NULL  COMMENT 'Cast from VARCHAR using TRY_TO_TIMESTAMP.',
    READING_DATE        DATE              NOT NULL  COMMENT 'DATE portion of READING_TIMESTAMP. Computed at load time for partitioning convenience.',
    HEART_RATE          NUMBER(6,2)       NOT NULL  COMMENT 'Heart rate in bpm. Cast and range-validated.',
    GLUCOSE_LEVEL       NUMBER(8,2)       NOT NULL  COMMENT 'Blood glucose in mg/dL. Cast and range-validated.',
    OXYGEN_SATURATION   NUMBER(5,2)       NOT NULL  COMMENT 'SpO2 percentage. Cast and range-validated.',
    DEVICE_ID           VARCHAR(50)       NOT NULL  COMMENT 'Validated FK to SILVER.CLEAN_DEVICES.',

    _SOURCE_FILE        VARCHAR(500)               COMMENT 'Source filename from Bronze row.',
    _BRONZE_INGESTED_AT TIMESTAMP_NTZ              COMMENT 'Ingestion timestamp from Bronze row.',
    _SILVER_LOADED_AT   TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
                                                   COMMENT 'Timestamp when this row was inserted or last updated in Silver.',
    CONSTRAINT PK_CLEAN_READINGS PRIMARY KEY (READING_ID)
)
COMMENT = 'Cleaned and validated patient readings promoted from BRONZE.RAW_READINGS. Only records passing all quality checks are present.';


-- =============================================================================
-- VALIDATION
-- =============================================================================
SHOW TABLES IN SCHEMA SILVER;
-- Expected: 3 tables — CLEAN_PATIENTS, CLEAN_DEVICES, CLEAN_READINGS

DESC TABLE SILVER.CLEAN_READINGS;
-- Verify HEART_RATE, GLUCOSE_LEVEL, OXYGEN_SATURATION are NUMBER types (not VARCHAR).

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
