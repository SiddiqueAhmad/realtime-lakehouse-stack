-- Scenario 3: Out-of-order replay (ordering, across separate deliveries)
--
-- Distinct from scenario 01 (duplicate_event: the SAME event delivered
-- twice) and scenario 02 (transaction_order: two DIFFERENT events in one
-- transaction, in commit order). This is two different events delivered
-- OUT of commit order — a newer one merged first, then an older one
-- arriving late (e.g. during redelivery/replay after an outage, per
-- scenario 12). In steady state Debezium delivers events in WAL/LSN order,
-- so this can't be produced by writing to Postgres directly; we reproduce
-- it against the raw Iceberg CDC table Debezium writes to, using explicit
-- LSNs so the ordering under test is unambiguous.
--
-- Run: trino --server localhost:8080 --catalog iceberg -f 03_out_of_order_replay.sql
--
-- (created_at/updated_at/__transaction_* are omitted below — Iceberg's
-- schema evolution makes them optional columns, and this scenario doesn't
-- need them; __source_lsn is the one CDC metadata field the reliability
-- engine actually orders/merges on, so it's the one that matters here.)

-- 1. The "current" (higher-LSN, i.e. newer) event: potassium result of 4.2.
INSERT INTO icebergdata.debeziumcdc_dbz__ehr_lab_results
    (lab_result_id, patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at, __op, __table, __source_ts_ns, __source_lsn, __db)
VALUES (9001, 2, 2, '2823-3', 'Potassium', 4.2, 'mmol/L', 'N', TIMESTAMP '2026-03-01 08:00:00',
        'u', 'lab_results', CAST(to_unixtime(TIMESTAMP '2026-03-01 08:00:00') * 1e9 AS BIGINT), 900000002, 'ehr');

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_lab_results sl_lab_results --profiles-dir .

-- 2. A REPLAYED, LOWER-LSN event for the same key arriving late: a stale
--    3.9 reading that — per its LSN — happened before the update above,
--    even though it's being delivered after it. This is the scenario
--    under test.
INSERT INTO icebergdata.debeziumcdc_dbz__ehr_lab_results
    (lab_result_id, patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at, __op, __table, __source_ts_ns, __source_lsn, __db)
VALUES (9001, 2, 2, '2823-3', 'Potassium', 3.9, 'mmol/L', 'N', TIMESTAMP '2026-03-01 07:00:00',
        'u', 'lab_results', CAST(to_unixtime(TIMESTAMP '2026-03-01 07:00:00') * 1e9 AS BIGINT), 900000001, 'ehr');

-- Then run dbt again: ../.venv/bin/dbt run --select br_lab_results sl_lab_results --profiles-dir .
--
-- EXPECTED: the row for lab_result_id = 9001 still shows result_value = 4.2.
-- The lower-LSN, out-of-order event must be a no-op — never a regression to
-- a stale clinical value.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT result_value, cdc_source_lsn FROM bronze.br_lab_results WHERE lab_result_id = 9001;
--   -- result_value = 4.2, cdc_source_lsn = 900000002
