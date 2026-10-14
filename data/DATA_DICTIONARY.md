# Data Dictionary — Healthcare Patient Monitoring

> **Disclaimer:** All data in this project is entirely fictional and synthetic.
> It is created solely for educational purposes. No real patient information is
> used. Any numeric thresholds shown are illustrative examples only and are
> **not** clinically validated values.

---

## Overview

The source data consists of three CSV files placed in the `data/` directory.
They model a fictional patient-monitoring system where wearable or bedside
devices record heart rate, blood glucose, and oxygen saturation for a cohort
of patients.

---

## 1. `patients.csv`

One row per patient. Represents the patient master record.

| Column              | Type (source CSV) | Description                                              | Nullable | Notes                                  |
|---------------------|-------------------|----------------------------------------------------------|----------|----------------------------------------|
| `patient_id`        | VARCHAR           | Unique patient identifier. Format: `P` + 3-digit number. | No       | Primary key for patient dimension.     |
| `age`               | INTEGER           | Patient age in years at time of registration.            | No       | Expected range: 18–120.                |
| `gender`            | VARCHAR           | Patient gender. Values: `Male`, `Female`, `Other`.       | No       | Standardised to title case in Silver.  |
| `registration_date` | DATE (YYYY-MM-DD) | Date the patient was registered in the system.           | No       | ISO 8601 format.                       |
| `city`              | VARCHAR           | City of patient residence.                               | No       | Free-text; not validated.              |

**Intentional quality issues in source file:** None for patients — this file is clean.

---

## 2. `devices.csv`

One row per monitoring device.

| Column           | Type (source CSV) | Description                                                                    | Nullable | Notes                                                           |
|------------------|-------------------|--------------------------------------------------------------------------------|----------|-----------------------------------------------------------------|
| `device_id`      | VARCHAR           | Unique device identifier. Format: `D` + 3-digit number.                        | No       | Primary key for device dimension.                               |
| `device_type`    | VARCHAR           | Type of device. Values: `Heart Rate Monitor`, `Glucose Monitor`, `Pulse Oximeter`, `Multi-Parameter Monitor`. | No | Used in Silver standardisation. |
| `manufacturer`   | VARCHAR           | Device manufacturer name.                                                      | No       | Free-text.                                                      |
| `deployment_date`| DATE (YYYY-MM-DD) | Date the device was put into service.                                           | No       | ISO 8601 format.                                                |
| `device_status`  | VARCHAR           | Operational status. Values: `Active`, `Maintenance`, `Retired`.                | No       | Standardised to title case in Silver. Retired devices flagged. |

**Intentional quality issues in source file:** None for devices — this file is clean.

---

## 3. `patient_readings.csv`

One row per measurement event. This is the primary fact table.

| Column               | Type (source CSV) | Description                                                              | Nullable | Notes                                                              |
|----------------------|-------------------|--------------------------------------------------------------------------|----------|--------------------------------------------------------------------|
| `reading_id`         | VARCHAR           | Unique reading identifier. Format: `R` + 4-digit number.                 | No       | Primary key for readings fact. Duplicates are intentionally present.|
| `patient_id`         | VARCHAR           | Foreign key to `patients.csv`.                                           | No       | Some rows have missing or unknown patient IDs (intentional).       |
| `reading_timestamp`  | TIMESTAMP (VARCHAR in raw) | Date and time of the reading. Expected format: `YYYY-MM-DD HH:MM:SS`. | No | Some rows have malformed timestamps (intentional).       |
| `heart_rate`         | NUMBER (VARCHAR in raw) | Heart rate in beats per minute (bpm).                             | No       | Expected illustrative range: 40–180. Some rows have text or out-of-range values (intentional). |
| `glucose_level`      | NUMBER (VARCHAR in raw) | Blood glucose level in mg/dL.                                     | No       | Expected illustrative range: 50–500. Some rows have extreme values (intentional). |
| `oxygen_saturation`  | NUMBER (VARCHAR in raw) | Blood oxygen saturation percentage (SpO2).                        | No       | Expected illustrative range: 85–100. Some rows have out-of-range values (intentional). |
| `device_id`          | VARCHAR           | Foreign key to `devices.csv`.                                            | No       | Some rows reference unknown device IDs (intentional).             |

---

## Intentional Data Quality Problems

The following problems are deliberately embedded in `patient_readings.csv` to
demonstrate Silver-layer rejection logic. The table below maps each problem to
the row(s) where it appears.

| Row (reading_id) | Problem Category               | Description                                                                    |
|------------------|--------------------------------|--------------------------------------------------------------------------------|
| R0683            | Missing mandatory field        | `patient_id` is empty.                                                         |
| R0684            | Unknown foreign key            | `patient_id` = `P999` — does not exist in `patients.csv`.                     |
| R0685            | Invalid numeric value          | `heart_rate` = `abc` — cannot be converted to a number.                       |
| R0686            | Malformed timestamp            | `reading_timestamp` = `NOT_A_DATE` — cannot be parsed as a timestamp.         |
| R0687            | Out-of-range numeric value     | `heart_rate` = `-5` — below the illustrative plausibility minimum of 40.     |
| R0688            | Out-of-range numeric value     | `oxygen_saturation` = `115` — above the illustrative maximum of 100.         |
| R0689            | Out-of-range numeric value     | `heart_rate` = `220` — above the illustrative plausibility maximum of 180.   |
| R0690            | Unknown foreign key            | `device_id` = `D999` — does not exist in `devices.csv`.                      |
| R0691            | Missing mandatory field        | `heart_rate` is empty (NULL after load).                                      |
| R0692            | Missing mandatory field        | `oxygen_saturation` is empty (NULL after load).                               |
| R0693            | Missing mandatory field        | `device_id` is empty (NULL after load).                                       |
| R0694            | Out-of-range numeric value     | `glucose_level` = `2500.0` — above the illustrative plausibility maximum of 600. |
| R0695, R0696     | Duplicate reading ID           | `reading_id` = `R0695` and `R0696` are identical rows — exact duplicate.     |
| R0700            | Malformed timestamp            | `reading_timestamp` = `2024-13-01 07:00:00` — month `13` is invalid.        |
| R0680, R0681, R0682 | Duplicate reading IDs      | These duplicate rows for R0001, R0011, R0020 test deduplication logic.       |

> **Note:** Rows R0680–R0682 re-use the same `reading_id` values as R0001, R0011, and
> R0020 respectively, but appear later in the file to simulate duplicate ingestion.
> The deduplication rule in the Silver layer retains the first occurrence by
> `reading_id` ordered by `reading_timestamp` then `_ingestion_timestamp`.

---

## Illustrative Plausibility Thresholds (NOT clinically validated)

These thresholds are used in the Silver and Gold layers for demonstration purposes only.
They are stored in `CONTROL.QUALITY_THRESHOLDS` so they can be adjusted without rewriting SQL.

| Metric               | Min  | Max  | Alert Min | Alert Max | Notes                          |
|----------------------|------|------|-----------|-----------|--------------------------------|
| `heart_rate`         | 40   | 180  | 100       | 160       | Beats per minute (bpm)         |
| `glucose_level`      | 50   | 600  | 180       | 400       | mg/dL                          |
| `oxygen_saturation`  | 85   | 100  | —         | —         | %; values below 92 flagged     |

---

## Relationships

```
patients (patient_id) ←── patient_readings (patient_id)
devices  (device_id)  ←── patient_readings (device_id)
```

All foreign keys in `patient_readings.csv` should reference valid rows in
`patients.csv` and `devices.csv`. Readings with unresolvable foreign keys are
rejected to `CONTROL.REJECTED_RECORDS` in the Silver layer.
