-- =============================================================================
-- File        : 01_create_database_schemas.sql
-- Layer       : Setup
-- Description : Creates the HEALTHCARE_MONITORING_DB database and all four
--               schemas: BRONZE, SILVER, GOLD, CONTROL.
-- Run order   : 1 — must be executed before any other script.
-- Idempotent  : Yes — uses CREATE ... IF NOT EXISTS throughout.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 1: Use the appropriate role and warehouse.
-- Replace SYSADMIN and COMPUTE_WH with the role/warehouse available in your
-- Snowflake account. Do NOT hardcode credentials here.
-- -----------------------------------------------------------------------------
USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;   -- Change to your warehouse name if different.

-- -----------------------------------------------------------------------------
-- STEP 2: Create the database.
-- A Snowflake database is the top-level container for schemas and objects.
-- IF NOT EXISTS makes this script safe to rerun without destroying existing data.
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS HEALTHCARE_MONITORING_DB
    COMMENT = 'Fictional healthcare patient monitoring data pipeline — educational project only. Contains no real patient data.';

-- Switch into the new database so subsequent statements apply to it.
USE DATABASE HEALTHCARE_MONITORING_DB;

-- -----------------------------------------------------------------------------
-- STEP 3: Create schemas.
-- Each schema represents a Medallion layer or a supporting concern.
--
-- BRONZE  — Raw ingested data. Append-only. All columns VARCHAR.
-- SILVER  — Cleaned, typed, validated data.
-- GOLD    — Aggregated analytics-ready tables.
-- CONTROL — Pipeline logs, quality logs, rejected records, configuration.
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS BRONZE
    COMMENT = 'Raw ingestion layer. Data loaded directly from CSV files via COPY INTO. All measurement columns stored as VARCHAR to preserve original values.';

CREATE SCHEMA IF NOT EXISTS SILVER
    COMMENT = 'Cleaned and validated layer. Type-cast, deduplicated, and reference-checked data promoted from Bronze.';

CREATE SCHEMA IF NOT EXISTS GOLD
    COMMENT = 'Analytics layer. Aggregated summaries, alerts, and trend tables derived from Silver.';

CREATE SCHEMA IF NOT EXISTS CONTROL
    COMMENT = 'Pipeline control layer. Contains rejected records, pipeline run logs, data quality check logs, and configurable thresholds.';

-- -----------------------------------------------------------------------------
-- STEP 4: Validation — confirm all objects were created.
-- Run these SELECT statements after the script completes to verify.
-- -----------------------------------------------------------------------------
SHOW DATABASES LIKE 'HEALTHCARE_MONITORING_DB';
SHOW SCHEMAS IN DATABASE HEALTHCARE_MONITORING_DB;

-- Expected output: 4 schemas — BRONZE, SILVER, GOLD, CONTROL
-- (plus the system-created INFORMATION_SCHEMA and PUBLIC schemas)

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
