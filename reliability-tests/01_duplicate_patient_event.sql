-- Scenario 1: Duplicate patient event (idempotency / dedup)
--
-- Two rapid updates to the same patient inside one transaction generate two
-- CDC events for the same key, likely landed in the same micro-batch. The
-- reliability engine (cdc_reliable_select, see warehouse/macros/cdc_reliability.sql)
-- must collapse them to the latest one rather than producing two rows or
-- applying the intermediate value.
--
-- Run: psql "postgresql://testuser:testpass@localhost:5433/ehr" -f 01_duplicate_patient_event.sql

BEGIN;
UPDATE ehr.patients SET phone = '555-010-9901' WHERE medical_record_number = 'MRN-SYN-00001';
UPDATE ehr.patients SET phone = '555-010-9902' WHERE medical_record_number = 'MRN-SYN-00001';
COMMIT;

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_patients sl_patients --profiles-dir .
--
-- EXPECTED: exactly one row for this patient, phone = '555-010-9902'
-- (last write wins) — never two rows, never the intermediate '555-010-9901'.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT count(*) AS row_count, max_by(phone, cdc_source_ts_ns) AS latest_phone
--   FROM bronze.br_patients
--   WHERE medical_record_number = 'MRN-SYN-00001';
--   -- row_count = 1, latest_phone = '555-010-9902'
