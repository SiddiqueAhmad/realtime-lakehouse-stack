-- Scenario 8: Unauthorized PHI access (minimum-necessary access control)
--
-- Requires infra-setup/trino/access-control.properties to be enabled (see
-- that directory's access-control.properties.example) and Trino restarted.
--
-- Trino's file-based access control keys off the submitted client user, so
-- this is testable with the CLI's --user flag alone — no separate identity
-- provider needed for the demonstration.

-- As an "analyst" user: PHI columns should be columns-denied, not just
-- values hidden — the query below should fail to resolve those columns.
-- trino --server localhost:8080 --catalog iceberg --user analyst_jane --execute \
--   "SELECT first_name, last_name, medical_record_number FROM bronze.br_patients LIMIT 1"
-- EXPECTED: Access Denied (column not accessible), not a result set.

-- The same analyst user CAN see non-PHI + quality metadata on the same table:
-- trino --server localhost:8080 --catalog iceberg --user analyst_jane --execute \
--   "SELECT patient_id, gender, state, quality_status FROM silver.sl_patients LIMIT 5"
-- EXPECTED: succeeds.

-- And CAN read the de-identified / aggregate layers freely:
-- trino --server localhost:8080 --catalog iceberg --user analyst_jane --execute \
--   "SELECT * FROM deid.patients_deidentified LIMIT 5"
-- trino --server localhost:8080 --catalog iceberg --user analyst_jane --execute \
--   "SELECT * FROM gold.daily_encounter_summary LIMIT 5"
-- EXPECTED: both succeed.

-- A "clinical_user" keeps full access (matches the default catch-all rule):
-- trino --server localhost:8080 --catalog iceberg --user clinical_user_bob --execute \
--   "SELECT first_name, last_name, medical_record_number FROM bronze.br_patients LIMIT 1"
-- EXPECTED: succeeds.
