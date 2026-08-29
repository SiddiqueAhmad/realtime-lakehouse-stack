-- Scenario 4: Deleted diagnosis (delete handling / auditability)
--
-- A deleted source row must not just vanish downstream: it should be
-- retained with is_deleted = true (see cdc_reliable_select), so we can
-- still answer "what happened to this record and when" — and it must drop
-- out of the silver/quality/trusted views, which filter `where not is_deleted`.
--
-- Run: psql "postgresql://testuser:testpass@localhost:5433/ehr" -f 04_deleted_diagnosis.sql

DELETE FROM ehr.diagnoses WHERE diagnosis_id = 3; -- J06.9, patient 3

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_diagnoses sl_diagnoses trusted_diagnoses --profiles-dir .
--
-- EXPECTED:
--   - bronze.br_diagnoses still has a row for diagnosis_id = 3, with
--     is_deleted = true and cdc_operation = 'd' (audit trail preserved).
--   - silver.sl_diagnoses and quality.trusted_diagnoses no longer include it.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT is_deleted, cdc_operation FROM bronze.br_diagnoses WHERE diagnosis_id = 3;
--   -- is_deleted = true, cdc_operation = 'd'
--   SELECT count(*) FROM silver.sl_diagnoses WHERE diagnosis_id = 3;
--   -- 0
