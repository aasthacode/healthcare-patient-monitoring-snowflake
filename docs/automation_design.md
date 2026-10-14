# Automation Design — Snowflake Streams and Tasks

> This document describes the Streams and Tasks design used to automate
> incremental processing of new patient readings once the manual pipeline has
> been validated.
>
> **Important:** Creating Streams and Tasks does not load data or execute SQL
> automatically. Tasks must be explicitly **resumed** before they will run.
> See the Activation section below.

---

## Overview

After the initial full-load pipeline is working, Snowflake Streams and Tasks
replace the need to run transformation SQL scripts manually each time new
readings arrive.

| Component            | Object Name                        | Type      | Role                                                        |
|----------------------|------------------------------------|-----------|-------------------------------------------------------------|
| Change capture       | `BRONZE.READINGS_STREAM`           | Stream    | Tracks new rows inserted into `BRONZE.RAW_READINGS`.        |
| Silver incremental   | `SILVER_INCREMENTAL_TASK`          | Task      | Consumes stream; runs Silver cleaning on new rows only.     |
| Gold refresh         | `GOLD_REFRESH_TASK`                | Task      | Refreshes Gold tables after Silver completes.               |
| Pipeline logging     | `PIPELINE_LOG_TASK`                | Task      | Writes pipeline completion metadata to `PIPELINE_RUN_LOG`.  |

---

## How Snowflake Streams Work

A Snowflake **Stream** is an object that records the Data Manipulation Language
(DML) changes — inserts, updates, and deletes — made to a source table after
the stream was created (or after it was last consumed).

Key concepts:
- A stream does not store data; it stores a **change token** pointing to a
  specific table version.
- When a task reads from the stream inside a transaction and the transaction
  commits, the stream's **offset advances**. The consumed rows no longer appear
  in the stream.
- If the transaction is rolled back, the stream offset does **not** advance,
  so the rows are reprocessed on the next run. This provides at-least-once
  delivery semantics.
- Streams have a **staleness window** (14 days by default on Standard Edition).
  If no task consumes the stream within that window, it becomes stale and must
  be recreated.

---

## Stream Definition

```sql
-- Tracks inserts into RAW_READINGS.
-- APPEND_ONLY = TRUE means the stream only captures new inserts,
-- not updates or deletes, which is appropriate for this append-only source table.
CREATE OR REPLACE STREAM BRONZE.READINGS_STREAM
    ON TABLE BRONZE.RAW_READINGS
    APPEND_ONLY = TRUE
    COMMENT = 'Captures new rows inserted into RAW_READINGS for incremental Silver processing.';
```

---

## Task Dependency Graph

```
SILVER_INCREMENTAL_TASK  (root task — scheduled every 15 minutes)
        │
        └──► GOLD_REFRESH_TASK  (child — runs when Silver task succeeds)
                    │
                    └──► PIPELINE_LOG_TASK  (child — runs when Gold task succeeds)
```

The root task (`SILVER_INCREMENTAL_TASK`) is scheduled. Child tasks do not
have their own schedules — they run only when their parent succeeds.

---

## Task Definitions

### SILVER_INCREMENTAL_TASK (Root Task)

- **Schedule:** Every 15 minutes (configurable via `SCHEDULE = '15 MINUTE'`).
- **WHEN condition:** Only runs if the stream has data (`SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM')`).
- **Action:** Calls the Silver incremental merge logic on rows from the stream.
- **Warehouse:** Uses `HCM_WAREHOUSE` (X-SMALL or appropriate size).

### GOLD_REFRESH_TASK (Child Task)

- **Trigger:** Runs after `SILVER_INCREMENTAL_TASK` succeeds.
- **Action:** Refreshes `GOLD.DAILY_PATIENT_SUMMARY`, `GOLD.READING_ALERTS`,
  and `GOLD.PATIENT_TRENDS`.
- **Approach for DAILY_PATIENT_SUMMARY:** Uses a targeted MERGE or partial
  refresh for dates affected by the new Silver records, not a full table rebuild.

### PIPELINE_LOG_TASK (Child Task)

- **Trigger:** Runs after `GOLD_REFRESH_TASK` succeeds.
- **Action:** Writes a completion row to `CONTROL.PIPELINE_RUN_LOG`.

---

## Transaction and Stream Consumption Boundary

The Silver task wraps its work in an explicit transaction:

```sql
BEGIN TRANSACTION;

    -- Step 1: Read new rows from the stream into a temp table.
    CREATE OR REPLACE TEMPORARY TABLE TEMP_NEW_READINGS AS
    SELECT * FROM BRONZE.READINGS_STREAM;  -- consumes the stream

    -- Step 2: Apply Silver cleaning logic on TEMP_NEW_READINGS.
    MERGE INTO SILVER.CLEAN_READINGS ...;

    -- Step 3: Insert rejections.
    INSERT INTO CONTROL.REJECTED_RECORDS ...;

COMMIT;  -- stream offset advances here
```

If the MERGE or INSERT fails, the ROLLBACK prevents the stream from advancing,
ensuring that the same records are reprocessed on the next scheduled run.

---

## Incremental Gold Maintenance

When new Silver rows arrive, they may affect historical dates if late-arriving
data is loaded. The Gold refresh task handles this by:

1. Identifying the **minimum date** among newly inserted `CLEAN_READINGS` rows.
2. Deleting Gold summary rows for that date and later from `DAILY_PATIENT_SUMMARY`.
3. Re-inserting summaries for the affected date range from Silver.

This ensures late-arriving records correctly update historical aggregates.

---

## Required Privileges

The role executing the tasks must have:

```sql
GRANT EXECUTE TASK ON ACCOUNT TO ROLE <your_role>;
GRANT USAGE ON WAREHOUSE HCM_WAREHOUSE TO ROLE <your_role>;
GRANT INSERT, UPDATE, DELETE, SELECT ON ALL TABLES IN SCHEMA SILVER TO ROLE <your_role>;
GRANT INSERT, UPDATE, DELETE, SELECT ON ALL TABLES IN SCHEMA GOLD TO ROLE <your_role>;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA CONTROL TO ROLE <your_role>;
```

---

## Activation Commands

Tasks are created in a **SUSPENDED** state. To activate:

```sql
-- Activate in bottom-up order (children first, then root).
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.PIPELINE_LOG_TASK RESUME;
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.GOLD_REFRESH_TASK RESUME;
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.SILVER_INCREMENTAL_TASK RESUME;
```

To suspend:
```sql
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.SILVER_INCREMENTAL_TASK SUSPEND;
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.GOLD_REFRESH_TASK SUSPEND;
ALTER TASK HEALTHCARE_MONITORING_DB.PUBLIC.PIPELINE_LOG_TASK SUSPEND;
```

---

## Monitoring Task Execution

```sql
-- View last 10 task executions
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 10
))
ORDER BY SCHEDULED_TIME DESC;

-- Check stream staleness and unconsumed rows
SELECT SYSTEM$STREAM_HAS_DATA('BRONZE.READINGS_STREAM');
SHOW STREAMS LIKE 'READINGS_STREAM' IN SCHEMA BRONZE;
```

---

## Assumptions

- Snowflake Standard Edition or above (required for Tasks and Streams).
- A dedicated warehouse `HCM_WAREHOUSE` is created and available.
- The executing role has been granted `EXECUTE TASK` privilege at the account level.
- Tasks use Serverless compute model or a named warehouse — both are supported.
  The SQL scripts use a named warehouse for clarity.
- If using Snowflake Trial, task execution uses the COMPUTE_WH warehouse.
