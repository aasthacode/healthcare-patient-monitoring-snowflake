-- =============================================================================
-- File        : 01_create_stream.sql
-- Layer       : Automation
-- Description : Creates a Snowflake Stream on BRONZE.RAW_READINGS to capture
--               new rows loaded via COPY INTO for incremental Silver processing.
--
-- IMPORTANT CONCEPTS:
--   • A Stream does NOT store data. It stores a "change token" — a pointer to
--     the table version when the stream was last consumed.
--   • After the stream is created, it captures all new inserts/changes made
--     after that moment.
--   • The stream is consumed (its offset advances) only when a task reads it
--     inside a committed transaction.
--   • If the stream is not consumed within 14 days (Snowflake Standard Edition
--     default), it becomes STALE and must be recreated.
--   • CREATING a stream does NOT trigger any processing. Tasks do the work.
--
-- Run order   : After all manual pipeline steps are verified.
-- Idempotent  : Yes — uses CREATE OR REPLACE STREAM.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- STEP 1: Create the stream on RAW_READINGS.
--
-- APPEND_ONLY = TRUE is appropriate here because:
--   • RAW_READINGS is a Bronze table that is only ever appended to (no updates/deletes).
--   • APPEND_ONLY streams are more efficient than standard streams for insert-only tables.
--   • They do not capture update/delete metadata columns (METADATA$ACTION etc.)
--     which simplifies processing SQL.
-- =============================================================================
CREATE OR REPLACE STREAM BRONZE.READINGS_STREAM
    ON TABLE BRONZE.RAW_READINGS
    APPEND_ONLY = TRUE
    COMMENT = 'Tracks new rows inserted into BRONZE.RAW_READINGS. Consumed by SILVER_INCREMENTAL_TASK to drive incremental Silver processing.';


-- =============================================================================
-- STEP 2: Verify the stream was created successfully.
-- =============================================================================
SHOW STREAMS IN SCHEMA BRONZE;

-- Check whether the stream currently has unconsumed data:
SELECT SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM') AS HAS_NEW_DATA;
-- Returns TRUE if rows were loaded into RAW_READINGS after the stream was created.
-- Returns FALSE if no new rows exist yet.

-- View stream metadata:
SELECT *
FROM BRONZE.READINGS_STREAM
LIMIT 5;
-- If no new rows have been loaded since the stream was created, this returns 0 rows.


-- =============================================================================
-- STEP 3: Notes on stream staleness.
--
-- If the stream becomes stale (no task consumes it within the staleness window):
--   1. Drop and recreate the stream:
--        DROP STREAM BRONZE.READINGS_STREAM;
--        CREATE STREAM BRONZE.READINGS_STREAM ON TABLE BRONZE.RAW_READINGS APPEND_ONLY = TRUE;
--
--   2. After recreating, the stream will track changes from the new creation point.
--      Any data loaded before recreation will NOT be reprocessed automatically.
--      If you need to reprocess historical data, run the full Silver load scripts
--      manually (sql/03_silver/) which process directly from the Bronze table.
--
-- To check stream stale status in Snowsight:
--   SHOW STREAMS IN SCHEMA BRONZE;
--   Look at the STALE column (TRUE = stale, FALSE = healthy).
-- =============================================================================

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
