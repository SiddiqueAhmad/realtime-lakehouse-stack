-- Scenario 2: Transaction ordering (same-transaction event ordering)
--
-- NOT the same guarantee as scenario 01 (duplicate_event): this is two
-- DIFFERENT events for the same key, committed in the same transaction —
-- e.g. an app that updates a row twice before committing. Postgres assigns
-- each row-level change its own strictly increasing LSN even within one
-- transaction (see warehouse/macros/cdc_reliability.sql), so the reliability
-- engine must apply them in that order and converge on the last one, not
-- treat them as the same event or apply them out of order.
--
-- Run: psql "postgresql://testuser:testpass@localhost:5433/ehr" -f 02_transaction_order.sql

-- Case A: two updates to one patient in one transaction.
BEGIN;
UPDATE ehr.patients SET phone = '555-010-9901' WHERE medical_record_number = 'MRN-SYN-00001';
UPDATE ehr.patients SET phone = '555-010-9902' WHERE medical_record_number = 'MRN-SYN-00001';
COMMIT;

-- Case B: same shape, on encounters instead of patients.
BEGIN;
UPDATE ehr.encounters SET status = 'in-progress' WHERE encounter_id = 2;
UPDATE ehr.encounters SET status = 'finished'    WHERE encounter_id = 2;
COMMIT;

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_patients sl_patients br_encounters sl_encounters --profiles-dir .
--
-- EXPECTED:
--   - exactly one row for the patient, phone = '555-010-9902' (last write
--     wins) — never two rows, never the intermediate '555-010-9901'.
--   - exactly one row for encounter_id = 2, status = 'finished'.
--
-- VERIFY (duckdb, via infra-setup/scripts/dq.py):
--   SELECT count(*) AS row_count, max_by(phone, cdc_source_lsn) AS latest_phone
--   FROM bronze.br_patients
--   WHERE medical_record_number = 'MRN-SYN-00001';
--   -- row_count = 1, latest_phone = '555-010-9902'
--
--   SELECT count(*) AS row_count, max_by(status, cdc_source_lsn) AS latest_status
--   FROM bronze.br_encounters
--   WHERE encounter_id = 2;
--   -- row_count = 1, latest_status = 'finished'
