-- Sanity checks run in CI against the Postgres side after scenarios 01, 03,
-- 04, 06, 07 have executed. This validates that each scenario's setup is
-- well-formed and lands the state it claims to at the SOURCE.
--
-- It does NOT validate the reliability/quality guarantees those scenarios
-- are actually about (dedup, ordering, quarantine, lineage) — those are
-- properties of the bronze/silver/quality layers downstream of
-- Debezium + Iceberg + Trino, which this CI job does not run. See
-- reliability-tests/README.md for how to verify those against the full
-- stack. Automating that end-to-end in CI is tracked as follow-up work.

DO $$
BEGIN
    ASSERT (SELECT phone FROM ehr.patients WHERE medical_record_number = 'MRN-SYN-00001') = '555-010-9902',
        'scenario 01: last write should win at the source';

    ASSERT (SELECT status FROM ehr.encounters WHERE encounter_id = 2) = 'finished',
        'scenario 03: last write should win at the source';

    ASSERT NOT EXISTS (SELECT 1 FROM ehr.diagnoses WHERE diagnosis_id = 3),
        'scenario 04: diagnosis should be physically deleted at the source (bronze retains it with is_deleted=true downstream)';

    ASSERT EXISTS (SELECT 1 FROM ehr.lab_results WHERE result_value = 55.0),
        'scenario 06: the implausible lab value should be present at the source (the plausibility gate is a downstream silver check)';

    ASSERT EXISTS (SELECT 1 FROM ehr.lab_results WHERE loinc_code = '2345-7' AND result_value IS NULL),
        'scenario 07: the null result_value should be present at the source (completeness gate is a downstream silver check)';

    RAISE NOTICE 'All Postgres-side scenario assertions passed.';
END $$;
