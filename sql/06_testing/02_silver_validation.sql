-- =============================================================================
-- File        : 02_silver_validation.sql
-- Layer       : Testing — Silver
-- Description : Validates Silver cleaning rules, deduplication, and rejection
--               handling. Run after all 03_silver/ scripts.
-- =============================================================================

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE HEALTHCARE_MONITORING_DB;

-- =============================================================================
-- TEST S-01: All 30 patients accepted into Silver
-- Expected: 30 rows in CLEAN_PATIENTS
-- =============================================================================
SELECT 'S-01' AS TEST_ID, 'All patients accepted' AS TEST_NAME,
       COUNT(*) AS ACTUAL_COUNT,
       CASE WHEN COUNT(*) = 30 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_PATIENTS;


-- =============================================================================
-- TEST S-02: All 15 devices accepted into Silver
-- Expected: 15 rows in CLEAN_DEVICES
-- =============================================================================
SELECT 'S-02' AS TEST_ID, 'All devices accepted' AS TEST_NAME,
       COUNT(*) AS ACTUAL_COUNT,
       CASE WHEN COUNT(*) = 15 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_DEVICES;


-- =============================================================================
-- TEST S-03: No patients or devices were rejected
-- Expected: 0 rows for SOURCE_TABLE IN patients/devices
-- =============================================================================
SELECT 'S-03' AS TEST_ID, 'No patient or device rejections' AS TEST_NAME,
       COUNT(*) AS REJECTED_COUNT,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE SOURCE_TABLE IN ('BRONZE.RAW_PATIENTS', 'BRONZE.RAW_DEVICES');


-- =============================================================================
-- TEST S-04: Specific bad rows were rejected with correct reason codes
-- =============================================================================

-- Missing patient_id (R0683) → MISSING_PATIENT_ID
SELECT 'S-04a' AS TEST_ID, 'R0683 rejected: MISSING_PATIENT_ID' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0683' AND REJECTION_REASON = 'MISSING_PATIENT_ID';

-- Unknown patient (R0684, P999) → UNKNOWN_PATIENT_ID
SELECT 'S-04b' AS TEST_ID, 'R0684 rejected: UNKNOWN_PATIENT_ID' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0684' AND REJECTION_REASON = 'UNKNOWN_PATIENT_ID';

-- Non-numeric heart rate (R0685, 'abc') → INVALID_HEART_RATE
SELECT 'S-04c' AS TEST_ID, 'R0685 rejected: INVALID_HEART_RATE' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0685' AND REJECTION_REASON = 'INVALID_HEART_RATE';

-- Malformed timestamp (R0686, 'NOT_A_DATE') → INVALID_TIMESTAMP
SELECT 'S-04d' AS TEST_ID, 'R0686 rejected: INVALID_TIMESTAMP' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0686' AND REJECTION_REASON = 'INVALID_TIMESTAMP';

-- Negative heart rate (R0687, -5) → HEART_RATE_OUT_OF_RANGE
SELECT 'S-04e' AS TEST_ID, 'R0687 rejected: HEART_RATE_OUT_OF_RANGE' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0687' AND REJECTION_REASON = 'HEART_RATE_OUT_OF_RANGE';

-- Oxygen saturation > 100 (R0688, 115) → OXYGEN_SAT_OUT_OF_RANGE
SELECT 'S-04f' AS TEST_ID, 'R0688 rejected: OXYGEN_SAT_OUT_OF_RANGE' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0688' AND REJECTION_REASON = 'OXYGEN_SAT_OUT_OF_RANGE';

-- Heart rate 220 → HEART_RATE_OUT_OF_RANGE
SELECT 'S-04g' AS TEST_ID, 'R0689 rejected: HEART_RATE_OUT_OF_RANGE' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0689' AND REJECTION_REASON = 'HEART_RATE_OUT_OF_RANGE';

-- Unknown device (R0690, D999) → UNKNOWN_DEVICE_ID
SELECT 'S-04h' AS TEST_ID, 'R0690 rejected: UNKNOWN_DEVICE_ID' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0690' AND REJECTION_REASON = 'UNKNOWN_DEVICE_ID';

-- Extreme glucose (R0694, 2500) → GLUCOSE_OUT_OF_RANGE
SELECT 'S-04i' AS TEST_ID, 'R0694 rejected: GLUCOSE_OUT_OF_RANGE' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0694' AND REJECTION_REASON = 'GLUCOSE_OUT_OF_RANGE';

-- Malformed month-13 timestamp (R0700) → INVALID_TIMESTAMP
SELECT 'S-04j' AS TEST_ID, 'R0700 rejected: INVALID_TIMESTAMP' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS
WHERE READING_ID = 'R0700' AND REJECTION_REASON = 'INVALID_TIMESTAMP';


-- =============================================================================
-- TEST S-05: Duplicate reading IDs rejected
-- R0695 and R0696 are identical — only one should survive in Silver.
-- Expected: R0695 in CLEAN_READINGS, R0696 in REJECTED_RECORDS
-- (because R0695 has an earlier row position / reading_id ordering)
-- =============================================================================
SELECT 'S-05a' AS TEST_ID, 'R0695 retained in Silver' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS WHERE READING_ID = 'R0695';

SELECT 'S-05b' AS TEST_ID, 'R0696 rejected as duplicate' AS TEST_NAME,
       COUNT(*) AS FOUND,
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM CONTROL.REJECTED_RECORDS WHERE READING_ID = 'R0696' AND REJECTION_REASON = 'DUPLICATE_READING_ID';


-- =============================================================================
-- TEST S-06: No Silver readings have NULL numeric values (type casts all succeeded)
-- Expected: 0 rows with NULL measurements in CLEAN_READINGS
-- =============================================================================
SELECT 'S-06' AS TEST_ID, 'No NULL measurements in Silver' AS TEST_NAME,
       COUNT(*) AS ROWS_WITH_NULLS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS
WHERE HEART_RATE IS NULL OR GLUCOSE_LEVEL IS NULL OR OXYGEN_SATURATION IS NULL;


-- =============================================================================
-- TEST S-07: All Silver readings have valid patient and device references
-- Expected: 0 orphaned readings
-- =============================================================================
SELECT 'S-07a' AS TEST_ID, 'All Silver readings have valid PATIENT_ID' AS TEST_NAME,
       COUNT(*) AS ORPHANED_ROWS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS cr
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER.CLEAN_PATIENTS cp WHERE cp.PATIENT_ID = cr.PATIENT_ID
);

SELECT 'S-07b' AS TEST_ID, 'All Silver readings have valid DEVICE_ID' AS TEST_NAME,
       COUNT(*) AS ORPHANED_ROWS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS cr
WHERE NOT EXISTS (
    SELECT 1 FROM SILVER.CLEAN_DEVICES cd WHERE cd.DEVICE_ID = cr.DEVICE_ID
);


-- =============================================================================
-- TEST S-08: Silver device statuses are standardised
-- Expected: only Active, Maintenance, Retired — no raw/mixed-case values
-- =============================================================================
SELECT 'S-08' AS TEST_ID, 'Device statuses standardised' AS TEST_NAME,
       DEVICE_STATUS, COUNT(*) AS CNT
FROM SILVER.CLEAN_DEVICES
WHERE DEVICE_STATUS NOT IN ('Active', 'Maintenance', 'Retired', 'Unknown')
GROUP BY DEVICE_STATUS;
-- Expected: 0 rows returned (all statuses are standardised)


-- =============================================================================
-- TEST S-09: CLEAN_READINGS has only readings within plausibility range
-- =============================================================================
SELECT 'S-09' AS TEST_ID, 'All readings within plausibility range' AS TEST_NAME,
       COUNT(*) AS OUT_OF_RANGE_ROWS,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS cr
WHERE cr.HEART_RATE       NOT BETWEEN 40  AND 180
   OR cr.GLUCOSE_LEVEL    NOT BETWEEN 50  AND 600
   OR cr.OXYGEN_SATURATION NOT BETWEEN 85 AND 100;


-- =============================================================================
-- TEST S-10: Silver is idempotent — rerunning Silver scripts does not duplicate
-- Run Silver scripts a second time, then:
-- Expected: row count unchanged
-- =============================================================================
SELECT 'S-10' AS TEST_ID, 'Silver idempotency check' AS TEST_NAME,
       COUNT(READING_ID)           AS TOTAL_ROWS,
       COUNT(DISTINCT READING_ID)  AS DISTINCT_READING_IDS,
       CASE WHEN COUNT(READING_ID) = COUNT(DISTINCT READING_ID)
            THEN 'PASS — no duplicates in Silver'
            ELSE 'FAIL — duplicate READING_IDs found' END AS TEST_RESULT
FROM SILVER.CLEAN_READINGS;

-- =============================================================================
-- END OF SILVER VALIDATION
-- =============================================================================
