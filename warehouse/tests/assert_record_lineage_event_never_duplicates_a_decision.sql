-- Singular test: no two CONSECUTIVE rows for the same record_token in
-- gold.record_lineage_event may share a decision_fingerprint. Passes when
-- this returns zero rows.
--
-- This is the checkable form of the retry-safety property
-- record_lineage_event's own docstring claims: a dbt run - retried or not
-- - that recomputes an identical decision must never append a new row for
-- it. The model's `changed` CTE already enforces this by comparing
-- against the last *logged* content for each record_token (not by
-- pipeline_run_id, which only labels who observed a change, not whether
-- one happened) - this test is a direct, standing check on that outcome
-- rather than a re-read of the Jinja logic that produces it.
--
-- lag() over event_sequence - the same ordering the model itself uses to
-- find "the last logged decision" (see record_lineage_event.sql's own
-- comment on why event_sequence, not logged_at/pipeline_run_id, is the
-- only field guaranteed to order/dedupe a record_token's history
-- correctly) - is the correct way to express "consecutive" here, not a
-- self-join on adjacent row numbers, which would need its own
-- tie-breaking logic that could drift from the model's.

with ordered as (

    select
        record_token,
        decision_fingerprint,
        event_sequence,
        lag(decision_fingerprint) over (
            partition by record_token
            order by event_sequence
        ) as previous_fingerprint
    from {{ ref('record_lineage_event') }}

)

select *
from ordered
where previous_fingerprint is not null
  and decision_fingerprint = previous_fingerprint
