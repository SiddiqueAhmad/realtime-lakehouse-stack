-- Singular test: record_lineage_event.previous_decision_fingerprint must
-- always equal the immediately-preceding row's own decision_fingerprint
-- for the same record_token, and must be null exactly when no preceding
-- row exists. Passes when this returns zero rows.
--
-- previous_decision_fingerprint exists so a downstream query can read a
-- decision transition straight off the row instead of reconstructing it
-- with its own LAG()/self-join over this table. That's only trustworthy if
-- the column is actually kept in sync with the model's own change
-- detection - this test recomputes "the real previous fingerprint" the
-- same way assert_record_lineage_event_never_duplicates_a_decision.sql
-- does (independently of record_lineage_event.sql's own Jinja) and checks
-- it against what the model actually stored.

with recomputed as (

    select
        record_token,
        decision_fingerprint,
        previous_decision_fingerprint as stored_previous_fingerprint,
        lag(decision_fingerprint) over (
            partition by record_token
            order by event_sequence
        ) as actual_previous_fingerprint
    from {{ ref('record_lineage_event') }}

)

select *
from recomputed
where stored_previous_fingerprint is distinct from actual_previous_fingerprint
