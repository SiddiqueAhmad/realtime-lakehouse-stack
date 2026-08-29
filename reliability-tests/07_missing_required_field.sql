-- Scenario 7: Missing required field (completeness gate)
--
-- result_value is nullable at the source (a lab can be ordered and not yet
-- resulted, or cancelled) — silver.sl_lab_results' missing_result_value
-- check is what turns "no value yet" into a visible, actionable quality
-- signal instead of a silently incomplete row flowing downstream.
--
-- Run: psql "postgresql://testuser:testpass@localhost:5433/ehr" -f 07_missing_required_field.sql

INSERT INTO ehr.lab_results (patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at)
VALUES (3, 3, '2345-7', 'Glucose', NULL, 'mg/dL', NULL, now());

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_lab_results sl_lab_results quarantine_lab_results --profiles-dir .
--
-- EXPECTED: quality_status = 'FAIL' with failed_checks including
-- 'missing_result_value'; quarantined, not trusted.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT quality_status, failed_checks FROM silver.sl_lab_results
--   WHERE patient_id = 3 AND loinc_code = '2345-7' AND result_value IS NULL;
--   -- quality_status = 'FAIL', failed_checks contains 'missing_result_value'
