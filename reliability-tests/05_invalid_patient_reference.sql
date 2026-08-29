-- Scenario 5: Invalid patient reference (referential integrity gate)
--
-- Postgres enforces the patient_id foreign key at the source, so this can't
-- be produced by writing to ehr.diagnoses directly — which is exactly why a
-- pipeline still needs its own referential-integrity check: cross-system
-- inconsistency (a downstream delete, a broken upstream load, a disabled
-- constraint during a bulk import) can still land an orphaned row in the
-- lake. We reproduce that by inserting directly into the raw Iceberg CDC
-- table Debezium writes to, referencing a patient_id that doesn't exist.
--
-- Run: trino --server localhost:8080 --catalog iceberg -f 05_invalid_patient_reference.sql
--
-- (created_at/updated_at/__transaction_* are omitted below for the same
-- reason as scenario 03; __source_lsn must be set — cdc_reliable_select's
-- incremental merge guard compares against it, and a null value there would
-- silently make this INSERT never appear in bronze at all, which is the
-- opposite of what this scenario needs to demonstrate.)

INSERT INTO icebergdata.debeziumcdc_dbz__ehr_diagnoses
    (id, encounter_id, patient_id, icd10_code, description, diagnosed_at, __op, __table, __source_ts_ns, __source_lsn, __db)
VALUES (9002, 1, 999999, 'Z00.00', 'Encounter for general adult medical examination',
        TIMESTAMP '2026-03-01 09:00:00', 'c', 'diagnoses',
        CAST(to_unixtime(TIMESTAMP '2026-03-01 09:00:00') * 1e9 AS BIGINT), 900000003, 'ehr');

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_diagnoses sl_diagnoses trusted_diagnoses quarantine_diagnoses --profiles-dir .
--
-- EXPECTED: the row lands in bronze (raw CDC history is immutable — we don't
-- lose it), fails the patient_not_found check in silver, and shows up in
-- quarantine_diagnoses, not trusted_diagnoses.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT quality_status, failed_checks FROM silver.sl_diagnoses WHERE diagnosis_id = 9002;
--   -- quality_status = 'FAIL', failed_checks contains 'patient_not_found'
--   SELECT count(*) FROM quality.trusted_diagnoses WHERE diagnosis_id = 9002;
--   -- 0
--   SELECT count(*) FROM quality.quarantine_diagnoses WHERE diagnosis_id = 9002;
--   -- 1
