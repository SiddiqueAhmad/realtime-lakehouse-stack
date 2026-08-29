-- Scenario 2: Out-of-order lab result delivery (ordering)
--
-- In steady state, Debezium event order == Postgres commit order, so this
-- can't be produced by writing to Postgres out of order. It DOES happen
-- during redelivery/replay (e.g. reprocessing from an earlier offset per
-- scenario 12), where a batch containing an older event arrives after a
-- newer one has already been merged. We reproduce that directly against the
-- raw Iceberg CDC table Debezium writes to, since WAL order can't be
-- reordered from the source.
--
-- Run: trino --server localhost:8080 --catalog iceberg -f 02_out_of_order_lab_result.sql
--
-- (created_at/updated_at are omitted below — Iceberg's schema evolution
-- makes them optional columns, and the reliability layer doesn't read them.)

-- 1. The "current" (newer) event: potassium result of 4.2 at 08:00.
INSERT INTO icebergdata.debeziumcdc_dbz__ehr_lab_results
    (id, patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at, __op, __table, __source_ts_ns, __db)
VALUES (9001, 2, 2, '2823-3', 'Potassium', 4.2, 'mmol/L', 'N', TIMESTAMP '2026-03-01 08:00:00',
        'u', 'lab_results', CAST(to_unixtime(TIMESTAMP '2026-03-01 08:00:00') * 1e9 AS BIGINT), 'ehr');

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_lab_results sl_lab_results --profiles-dir .

-- 2. A REPLAYED, older event for the same key arriving late: a stale 3.9
--    reading from 07:00, i.e. before the update above — the scenario under
--    test.
INSERT INTO icebergdata.debeziumcdc_dbz__ehr_lab_results
    (id, patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at, __op, __table, __source_ts_ns, __db)
VALUES (9001, 2, 2, '2823-3', 'Potassium', 3.9, 'mmol/L', 'N', TIMESTAMP '2026-03-01 07:00:00',
        'u', 'lab_results', CAST(to_unixtime(TIMESTAMP '2026-03-01 07:00:00') * 1e9 AS BIGINT), 'ehr');

-- Then run dbt again: ../.venv/bin/dbt run --select br_lab_results sl_lab_results --profiles-dir .
--
-- EXPECTED: the row for lab_result_id = 9001 still shows result_value = 4.2.
-- The older, out-of-order event must be a no-op — never a regression to a
-- stale clinical value.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT result_value, cdc_source_ts_ns FROM bronze.br_lab_results WHERE lab_result_id = 9001;
--   -- result_value = 4.2
