-- Scenario 1: Duplicate event (true redelivery — idempotency)
--
-- This is the guarantee "idempotency" actually names: the exact same CDC
-- event — same natural key, same LSN, same values — delivered twice, in
-- two SEPARATE deliveries (e.g. Debezium redelivers a batch because a
-- consumer restarted before committing its offset). That's a different
-- claim from scenario 02 (transaction_order: two DIFFERENT events, in
-- order) or scenario 03 (out_of_order_replay: two different events,
-- delivered out of order) — here the event itself is identical, not just
-- its key, and critically it's redelivered across two separate merges, not
-- deduplicated for free within one micro-batch.
--
-- We reproduce exact redelivery against the raw Iceberg CDC table Debezium
-- writes to (a real redelivery from Debezium can't be triggered on demand
-- from outside it).
--
-- Run: trino --server localhost:8080 --catalog iceberg -f 01_duplicate_event.sql
--
-- (created_at/updated_at/__transaction_* are omitted below for the same
-- reason as scenario 03.)

-- 1. First delivery of the event (fixed LSN 900000010).
INSERT INTO icebergdata.debeziumcdc_dbz__ehr_patients
    (id, medical_record_number, first_name, last_name, date_of_birth, gender, email, phone, address_line1, city, state, postal_code, is_deceased, __op, __table, __source_ts_ns, __source_lsn, __db)
VALUES (2, 'MRN-SYN-00002', 'Morgan', 'Sample', DATE '1972-11-02', 'male', 'morgan.sample+updated@synthetic.test', '555-010-0002', '2 Synthetic Way', 'Springfield', 'IL', '62701', false,
        'u', 'patients', CAST(to_unixtime(TIMESTAMP '2026-03-02 09:00:00') * 1e9 AS BIGINT), 900000010, 'ehr');

-- Then: cd warehouse && ../.venv/bin/dbt run --select br_patients sl_patients --profiles-dir .

-- 2. REDELIVERY of the exact same event — same id, same LSN, same values —
--    as its own separate INSERT, processed by its own separate dbt run.
--    This is the scenario under test: not same-batch dedup (which
--    cdc_reliable_select's row_number() already handles trivially), but
--    idempotency ACROSS two merges of the identical event.
INSERT INTO icebergdata.debeziumcdc_dbz__ehr_patients
    (id, medical_record_number, first_name, last_name, date_of_birth, gender, email, phone, address_line1, city, state, postal_code, is_deceased, __op, __table, __source_ts_ns, __source_lsn, __db)
VALUES (2, 'MRN-SYN-00002', 'Morgan', 'Sample', DATE '1972-11-02', 'male', 'morgan.sample+updated@synthetic.test', '555-010-0002', '2 Synthetic Way', 'Springfield', 'IL', '62701', false,
        'u', 'patients', CAST(to_unixtime(TIMESTAMP '2026-03-02 09:00:00') * 1e9 AS BIGINT), 900000010, 'ehr');
-- (Both INSERTs land in the append-only raw log — that's expected and
-- correct: the raw layer keeps every delivery, redeliveries included. It's
-- bronze's job to converge them to one effect.)

-- Then run dbt again: ../.venv/bin/dbt run --select br_patients sl_patients --profiles-dir .
--
-- EXPECTED: exactly one row in bronze for patient_id = 2, with
-- email = 'morgan.sample+updated@synthetic.test'. The second merge must be
-- a pure no-op — cdc_source_lsn 900000010 is not strictly greater than the
-- 900000010 already merged in step 1's dbt run (see the `>`, not `>=`, in
-- cdc_reliable_select's incremental merge guard) — not a second row and not
-- an error.
--
-- VERIFY (trino --server localhost:8080 --catalog iceberg):
--   SELECT count(*) AS row_count, max_by(email, cdc_source_lsn) AS latest_email
--   FROM bronze.br_patients
--   WHERE patient_id = 2;
--   -- row_count = 1, latest_email = 'morgan.sample+updated@synthetic.test'
--
-- Also worth checking directly against the raw log, to confirm the
-- distinction this scenario is making — the append-only layer really does
-- have 2 rows for this LSN (3, counting the original snapshot row for
-- patient 2), while bronze (post-reliability-engine) has exactly 1:
--   SELECT count(*) FROM icebergdata.debeziumcdc_dbz__ehr_patients WHERE id = 2 AND __source_lsn = 900000010;
--   -- 2
