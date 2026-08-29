-- Scenario 6: Impossible lab value (clinical plausibility gate)
--
-- ehr.lab_results has no CHECK constraint on result_value (clinical ranges
-- vary by test and shouldn't be hardcoded into the operational schema), so
-- an implausible value can legitimately reach the source — a transcription
-- error, a unit mixup, a faulty device. This is what
-- seeds/lab_reference_ranges.csv + the result_out_of_range check in
-- silver.sl_lab_results exists to catch.
--
-- Run: psql "postgresql://testuser:testpass@localhost:5433/ehr" -f 06_impossible_lab_value.sql

INSERT INTO ehr.lab_results (patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at)
VALUES (2, 2, '2823-3', 'Potassium', 55.0, 'mmol/L', 'HH', now());
-- 55 mmol/L potassium is not survivable; plausible bound from the seed is 1.0-10.0.

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_lab_results sl_lab_results quarantine_lab_results --profiles-dir .
--
-- EXPECTED: quality_status = 'FAIL' with failed_checks including
-- 'result_out_of_range'; the row appears in quarantine_lab_results, not
-- trusted_lab_results.
--
-- VERIFY (duckdb, via infra-setup/scripts/dq.py):
--   SELECT quality_status, failed_checks FROM silver.sl_lab_results WHERE result_value = 55.0;
--   -- quality_status = 'FAIL', failed_checks contains 'result_out_of_range'
