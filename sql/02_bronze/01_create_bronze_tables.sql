-- =============================================================================
-- File        : 01_create_bronze_tables.sql
-- Layer       : Bronze
-- Description : Creates the three raw ingestion tables in the BRONZE schema.
--               All measurement columns are VARCHAR to preserve original values
--               even if they are malformed (e.g., 'abc' in a numeric field).
--               _SOURCE_FILE and _INGESTION_TIMESTAMP are added as metadata.
-- Run order   : 4 — run after all 01_setup scripts.
-- Idempotent  : Yes — uses CREATE TABLE IF NOT EXISTS.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- TABLE: BRONZE.RAW_PATIENTS
-- Source: data/patients.csv
-- =============================================================================
CREATE TABLE IF NOT EXISTS BRONZE.RAW_PATIENTS (
    -- Source columns — stored as VARCHAR to match CSV strings exactly.
    PATIENT_ID          VARCHAR(50)       COMMENT 'Source: patient_id. Unique patient identifier.',
    AGE                 VARCHAR(10)       COMMENT 'Source: age. Stored as VARCHAR in case of non-numeric values.',
    GENDER              VARCHAR(50)       COMMENT 'Source: gender.',
    REGISTRATION_DATE   VARCHAR(50)       COMMENT 'Source: registration_date. Stored as VARCHAR; cast to DATE in Silver.',
    CITY                VARCHAR(100)      COMMENT 'Source: city.',

    -- Pipeline metadata columns (prefix _ to distinguish from source fields).
    _SOURCE_FILE        VARCHAR(500)      COMMENT 'Name of the CSV file this row was loaded from.',
    _INGESTION_TIMESTAMP TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
                                          COMMENT 'Timestamp when this row was inserted into the Bronze table.'
)
COMMENT = 'Bronze raw table for patient demographics. Loaded from patients.csv via COPY INTO. Do not modify after load.';


-- =============================================================================
-- TABLE: BRONZE.RAW_DEVICES
-- Source: data/devices.csv
-- =============================================================================
CREATE TABLE IF NOT EXISTS BRONZE.RAW_DEVICES (
    DEVICE_ID           VARCHAR(50)       COMMENT 'Source: device_id. Unique device identifier.',
    DEVICE_TYPE         VARCHAR(100)      COMMENT 'Source: device_type.',
    MANUFACTURER        VARCHAR(200)      COMMENT 'Source: manufacturer.',
    DEPLOYMENT_DATE     VARCHAR(50)       COMMENT 'Source: deployment_date. Stored as VARCHAR; cast to DATE in Silver.',
    DEVICE_STATUS       VARCHAR(50)       COMMENT 'Source: device_status.',

    _SOURCE_FILE        VARCHAR(500)      COMMENT 'Name of the CSV file this row was loaded from.',
    _INGESTION_TIMESTAMP TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
                                          COMMENT 'Timestamp when this row was inserted into the Bronze table.'
)
COMMENT = 'Bronze raw table for monitoring devices. Loaded from devices.csv via COPY INTO. Do not modify after load.';


-- =============================================================================
-- TABLE: BRONZE.RAW_READINGS
-- Source: data/patient_readings.csv
--
-- IMPORTANT: heart_rate, glucose_level, and oxygen_saturation are VARCHAR here.
-- The source file contains intentional non-numeric values (e.g., 'abc').
-- Storing them as VARCHAR means those rows load successfully rather than
-- causing the entire COPY INTO to fail. The Silver layer applies TRY_TO_NUMBER
-- to cast them properly and routes failures to CONTROL.REJECTED_RECORDS.
-- =============================================================================
CREATE TABLE IF NOT EXISTS BRONZE.RAW_READINGS (
    READING_ID          VARCHAR(50)       COMMENT 'Source: reading_id. Unique reading identifier.',
    PATIENT_ID          VARCHAR(50)       COMMENT 'Source: patient_id. Foreign key to RAW_PATIENTS.',
    READING_TIMESTAMP   VARCHAR(50)       COMMENT 'Source: reading_timestamp. Stored as VARCHAR; some rows have malformed timestamps.',
    HEART_RATE          VARCHAR(20)       COMMENT 'Source: heart_rate (bpm). VARCHAR to accept non-numeric values.',
    GLUCOSE_LEVEL       VARCHAR(20)       COMMENT 'Source: glucose_level (mg/dL). VARCHAR to accept non-numeric values.',
    OXYGEN_SATURATION   VARCHAR(20)       COMMENT 'Source: oxygen_saturation (%). VARCHAR to accept non-numeric values.',
    DEVICE_ID           VARCHAR(50)       COMMENT 'Source: device_id. Foreign key to RAW_DEVICES.',

    _SOURCE_FILE        VARCHAR(500)      COMMENT 'Name of the CSV file this row was loaded from.',
    _INGESTION_TIMESTAMP TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
                                          COMMENT 'Timestamp when this row was inserted into the Bronze table.'
)
COMMENT = 'Bronze raw table for patient readings. All measurement columns are VARCHAR to preserve malformed source values. Loaded from patient_readings.csv via COPY INTO.';


-- =============================================================================
-- VALIDATION — Run after this script to confirm tables were created.
-- =============================================================================
SHOW TABLES IN SCHEMA BRONZE;
-- Expected: 3 tables — RAW_PATIENTS, RAW_DEVICES, RAW_READINGS

-- Confirm column definitions for RAW_READINGS (verify VARCHAR types):
DESC TABLE BRONZE.RAW_READINGS;

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
