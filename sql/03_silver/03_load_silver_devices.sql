-- =============================================================================
-- File        : 03_load_silver_devices.sql
-- Layer       : Silver
-- Description : Cleans BRONZE.RAW_DEVICES and loads valid records into
--               SILVER.CLEAN_DEVICES. Rejected records go to CONTROL.REJECTED_RECORDS.
-- Run order   : 8 — run after 03_silver/02_load_silver_patients.sql
-- Idempotent  : Yes — uses MERGE on DEVICE_ID.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

SET SILVER_DEV_RUN_ID = UUID_STRING();
INSERT INTO CONTROL.PIPELINE_RUN_LOG
    (RUN_ID, PIPELINE_NAME, LAYER, STATUS, STARTED_AT, SOURCE_FILE)
VALUES
    ($SILVER_DEV_RUN_ID, 'SILVER_LOAD_DEVICES', 'SILVER', 'STARTED',
     CURRENT_TIMESTAMP(), 'devices.csv');


-- =============================================================================
-- STEP 1: Route invalid device records to CONTROL.REJECTED_RECORDS.
--
-- Rules applied (see docs/transformation_rules.md):
--   DEV-01: device_id must not be NULL or empty.
--   DEV-02: device_type must not be NULL.
--   DEV-03: device_status — if unrecognised, set to 'Unknown' (soft; still accepted).
--   DEV-04: deployment_date must convert to DATE successfully.
-- =============================================================================
INSERT INTO CONTROL.REJECTED_RECORDS
    (PIPELINE_RUN_ID, SOURCE_TABLE, READING_ID, PATIENT_ID, DEVICE_ID,
     REJECTION_REASON, RAW_ROW_SNAPSHOT, REJECTED_AT)
SELECT
    $SILVER_DEV_RUN_ID,
    'BRONZE.RAW_DEVICES',
    NULL, NULL,
    d.DEVICE_ID,
    CASE
        WHEN d.DEVICE_ID IS NULL OR TRIM(d.DEVICE_ID) = ''
            THEN 'MISSING_DEVICE_ID'
        WHEN d.DEVICE_TYPE IS NULL OR TRIM(d.DEVICE_TYPE) = ''
            THEN 'MISSING_DEVICE_TYPE'
        WHEN TRY_TO_DATE(d.DEPLOYMENT_DATE, 'YYYY-MM-DD') IS NULL
            THEN 'INVALID_DEPLOYMENT_DATE'
    END AS REJECTION_REASON,
    'device_id=' || COALESCE(d.DEVICE_ID,'NULL')
        || '|device_type=' || COALESCE(d.DEVICE_TYPE,'NULL')
        || '|deployment_date=' || COALESCE(d.DEPLOYMENT_DATE,'NULL') AS RAW_ROW_SNAPSHOT,
    CURRENT_TIMESTAMP()
FROM BRONZE.RAW_DEVICES d
WHERE
    (
        d.DEVICE_ID IS NULL OR TRIM(d.DEVICE_ID) = ''
        OR d.DEVICE_TYPE IS NULL OR TRIM(d.DEVICE_TYPE) = ''
        OR TRY_TO_DATE(d.DEPLOYMENT_DATE, 'YYYY-MM-DD') IS NULL
    )
    AND NOT EXISTS (
        SELECT 1 FROM CONTROL.REJECTED_RECORDS r
        WHERE r.DEVICE_ID = d.DEVICE_ID
          AND r.SOURCE_TABLE = 'BRONZE.RAW_DEVICES'
          AND r.REJECTION_REASON = CASE
                  WHEN d.DEVICE_ID IS NULL OR TRIM(d.DEVICE_ID) = '' THEN 'MISSING_DEVICE_ID'
                  WHEN d.DEVICE_TYPE IS NULL OR TRIM(d.DEVICE_TYPE) = '' THEN 'MISSING_DEVICE_TYPE'
                  WHEN TRY_TO_DATE(d.DEPLOYMENT_DATE, 'YYYY-MM-DD') IS NULL THEN 'INVALID_DEPLOYMENT_DATE'
              END
    );


-- =============================================================================
-- STEP 2: MERGE valid device records into SILVER.CLEAN_DEVICES.
--
-- DEV-03 soft rule: device_status is CASE-normalised.
--   If it is not one of the known values, it becomes 'Unknown' but the record
--   is still accepted (unlike a hard rejection rule).
-- =============================================================================
MERGE INTO SILVER.CLEAN_DEVICES AS target
USING (
    SELECT
        d.DEVICE_ID,
        INITCAP(TRIM(d.DEVICE_TYPE))                AS DEVICE_TYPE,
        TRIM(d.MANUFACTURER)                        AS MANUFACTURER,
        TRY_TO_DATE(d.DEPLOYMENT_DATE, 'YYYY-MM-DD') AS DEPLOYMENT_DATE,
        -- DEV-03: normalise status; anything unrecognised becomes 'Unknown'
        CASE
            WHEN UPPER(TRIM(d.DEVICE_STATUS)) IN ('ACTIVE','MAINTENANCE','RETIRED')
                THEN INITCAP(TRIM(d.DEVICE_STATUS))
            ELSE 'Unknown'
        END                                         AS DEVICE_STATUS,
        d._SOURCE_FILE,
        d._INGESTION_TIMESTAMP
    FROM BRONZE.RAW_DEVICES d
    WHERE
        d.DEVICE_ID IS NOT NULL
        AND TRIM(d.DEVICE_ID) != ''
        AND d.DEVICE_TYPE IS NOT NULL
        AND TRIM(d.DEVICE_TYPE) != ''
        AND TRY_TO_DATE(d.DEPLOYMENT_DATE, 'YYYY-MM-DD') IS NOT NULL
) AS source
ON target.DEVICE_ID = source.DEVICE_ID
WHEN MATCHED THEN UPDATE SET
    target.DEVICE_TYPE         = source.DEVICE_TYPE,
    target.MANUFACTURER        = source.MANUFACTURER,
    target.DEPLOYMENT_DATE     = source.DEPLOYMENT_DATE,
    target.DEVICE_STATUS       = source.DEVICE_STATUS,
    target._SOURCE_FILE        = source._SOURCE_FILE,
    target._BRONZE_INGESTED_AT = source._INGESTION_TIMESTAMP,
    target._SILVER_LOADED_AT   = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    DEVICE_ID, DEVICE_TYPE, MANUFACTURER, DEPLOYMENT_DATE, DEVICE_STATUS,
    _SOURCE_FILE, _BRONZE_INGESTED_AT, _SILVER_LOADED_AT
) VALUES (
    source.DEVICE_ID, source.DEVICE_TYPE, source.MANUFACTURER, source.DEPLOYMENT_DATE,
    source.DEVICE_STATUS, source._SOURCE_FILE, source._INGESTION_TIMESTAMP, CURRENT_TIMESTAMP()
);


-- =============================================================================
-- STEP 3: Update pipeline run log
-- =============================================================================
UPDATE CONTROL.PIPELINE_RUN_LOG
SET
    STATUS        = 'COMPLETED',
    COMPLETED_AT  = CURRENT_TIMESTAMP(),
    ROWS_INPUT    = (SELECT COUNT(*) FROM BRONZE.RAW_DEVICES),
    ROWS_ACCEPTED = (SELECT COUNT(*) FROM SILVER.CLEAN_DEVICES),
    ROWS_REJECTED = (SELECT COUNT(*) FROM CONTROL.REJECTED_RECORDS
                     WHERE PIPELINE_RUN_ID = $SILVER_DEV_RUN_ID),
    ROWS_INSERTED = (SELECT COUNT(*) FROM SILVER.CLEAN_DEVICES)
WHERE RUN_ID = $SILVER_DEV_RUN_ID;


-- =============================================================================
-- STEP 4: Validation
-- =============================================================================
SELECT COUNT(*) AS clean_devices_count FROM SILVER.CLEAN_DEVICES;
-- Expected: 15 (all device rows pass — devices.csv is clean)

-- Verify device statuses were standardised correctly:
SELECT DEVICE_STATUS, COUNT(*) AS CNT
FROM SILVER.CLEAN_DEVICES
GROUP BY DEVICE_STATUS
ORDER BY DEVICE_STATUS;
-- Expected values: Active, Maintenance, Retired (no 'Unknown' for clean data)

-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
