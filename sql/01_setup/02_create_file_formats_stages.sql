-- =============================================================================
-- File        : 02_create_file_formats_stages.sql
-- Layer       : Setup
-- Description : Creates the CSV file format and internal stage used for
--               loading source CSV files into the Bronze layer.
-- Run order   : 2 — run after 01_create_database_schemas.sql
-- Idempotent  : Yes — uses CREATE OR REPLACE throughout.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;
USE SCHEMA BRONZE;

-- -----------------------------------------------------------------------------
-- STEP 1: Create the CSV file format.
--
-- A FILE FORMAT in Snowflake tells the COPY INTO command how to interpret the
-- raw bytes of each file. Key settings explained:
--
--   TYPE = CSV           — source files are comma-separated values.
--   FIELD_DELIMITER      — columns are separated by commas.
--   RECORD_DELIMITER     — rows are separated by newlines.
--   SKIP_HEADER = 1      — the first row of each file is a header row; skip it.
--   FIELD_OPTIONALLY_ENCLOSED_BY — values may be wrapped in double quotes.
--   NULL_IF              — treat empty strings ('') as SQL NULL.
--   EMPTY_FIELD_AS_NULL  — an empty field (,,) becomes NULL.
--   ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE — a row with the wrong number of
--                          columns is not immediately fatal; Snowflake will
--                          attempt to load what it can. Combined with VARCHAR
--                          column types in Bronze, this preserves partial rows.
--   TRIM_SPACE = TRUE    — strip leading/trailing whitespace from field values.
--   DATE_FORMAT = AUTO   — let Snowflake auto-detect date formats.
--   TIMESTAMP_FORMAT = AUTO — same for timestamps.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT BRONZE.HCM_CSV_FORMAT
    TYPE                         = CSV
    FIELD_DELIMITER              = ','
    RECORD_DELIMITER             = '\n'
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('', 'NULL', 'null', 'N/A')
    EMPTY_FIELD_AS_NULL          = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    TRIM_SPACE                   = TRUE
    DATE_FORMAT                  = 'AUTO'
    TIMESTAMP_FORMAT             = 'AUTO'
    COMMENT = 'Standard CSV format for Healthcare Monitoring source files.';

-- Verify:
SHOW FILE FORMATS IN SCHEMA BRONZE;


-- -----------------------------------------------------------------------------
-- STEP 2: Create the internal stage.
--
-- A Snowflake INTERNAL STAGE is a Snowflake-managed file storage area inside
-- your account. You upload CSV files to the stage using the PUT command
-- (from SnowSQL CLI or Snowsight's Upload button), and then COPY INTO reads
-- from the stage into a table.
--
-- Using an internal stage means:
--   • No external cloud storage (S3, Azure Blob, GCS) is needed.
--   • Files are encrypted at rest by Snowflake automatically.
--   • No credentials to manage for storage.
--
-- DIRECTORY = (ENABLE = TRUE) allows you to query the stage like a table to
-- see which files are currently staged.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE STAGE BRONZE.HCM_STAGE
    FILE_FORMAT = BRONZE.HCM_CSV_FORMAT
    DIRECTORY   = (ENABLE = TRUE)
    COMMENT = 'Internal stage for Healthcare Monitoring source CSV files. Upload files here before running COPY INTO.';

-- Verify:
SHOW STAGES IN SCHEMA BRONZE;


-- -----------------------------------------------------------------------------
-- STEP 3: HOW TO UPLOAD FILES TO THE STAGE
--
-- Option A — SnowSQL CLI (command-line tool):
--   PUT file:///path/to/data/patients.csv         @BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
--   PUT file:///path/to/data/patient_readings.csv @BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
--   PUT file:///path/to/data/devices.csv          @BRONZE.HCM_STAGE AUTO_COMPRESS=FALSE;
--
-- Option B — Snowsight UI:
--   1. Navigate to Data > Databases > HEALTHCARE_MONITORING_DB > BRONZE > Stages > HCM_STAGE.
--   2. Click "+ Files" and upload patients.csv, patient_readings.csv, devices.csv.
--
-- After uploading, verify the files are visible:
LIST @BRONZE.HCM_STAGE;
-- Expected: three files — patients.csv, patient_readings.csv, devices.csv
-- (They may appear with .gz extension if auto-compressed.)


-- -----------------------------------------------------------------------------
-- STEP 4: UNDERSTANDING COPY INTO FILE-LOADING BEHAVIOUR
--
-- Snowflake tracks which files have already been loaded via an internal
-- load history. By default, COPY INTO will NOT reload a file that has already
-- been loaded from the same stage (FORCE = FALSE is the default).
--
-- This means:
--   • Re-running the Bronze COPY INTO scripts is safe — duplicate loads are
--     prevented automatically.
--   • If you genuinely need to reload a file (e.g., you fixed the CSV and
--     want to reload it), you have two options:
--
--     Option 1 — Use FORCE = TRUE in the COPY INTO statement:
--       COPY INTO BRONZE.RAW_PATIENTS
--       FROM @BRONZE.HCM_STAGE/patients.csv
--       FILE_FORMAT = (FORMAT_NAME = BRONZE.HCM_CSV_FORMAT)
--       FORCE = TRUE;
--     WARNING: FORCE = TRUE will reload the file even if it was already loaded,
--     potentially creating duplicates in the Bronze table. Only use this during
--     development/testing after truncating the target Bronze table.
--
--     Option 2 — Remove the file load history for that specific file:
--       ALTER TABLE BRONZE.RAW_PATIENTS MODIFY FILE LOAD STATUS ...
--     (This approach is more surgical but complex — FORCE=TRUE is simpler for dev.)
--
--   • The load history can be queried:
--       SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
--           TABLE_NAME => 'RAW_READINGS',
--           START_TIME => DATEADD('day', -7, CURRENT_TIMESTAMP())
--       ));
-- -----------------------------------------------------------------------------

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
