-- Scenario 3: Duplicate encounter event (idempotency / dedup)
--
-- Same shape as scenario 1, on the encounters table: two updates to one
-- encounter inside a transaction should collapse to one bronze/silver row.
--
-- Run: psql "postgresql://testuser:testpass@localhost:5433/ehr" -f 03_duplicate_encounter.sql

BEGIN;
UPDATE ehr.encounters SET status = 'in-progress' WHERE encounter_id = 2;
UPDATE ehr.encounters SET status = 'finished'    WHERE encounter_id = 2;
COMMIT;

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_encounters sl_encounters --profiles-dir .
--
-- EXPECTED: exactly one row for encounter_id = 2, status = 'finished'.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT count(*) AS row_count, max_by(status, cdc_source_ts_ns) AS latest_status
--   FROM bronze.br_encounters
--   WHERE encounter_id = 2;
--   -- row_count = 1, latest_status = 'finished'
