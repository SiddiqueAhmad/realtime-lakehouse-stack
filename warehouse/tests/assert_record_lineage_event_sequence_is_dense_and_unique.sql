-- Singular test: for every record_token, event_sequence must be exactly
-- {1, 2, 3, ..., count(*)} - no gaps, no duplicates, no value out of
-- range. Passes when this returns zero rows.
--
-- This is the formal version of "record_lineage_event's history for a
-- record_token has a real, unambiguous total order" that
-- assert_record_lineage_event_never_duplicates_a_decision.sql and
-- assert_record_lineage_event_previous_fingerprint_is_consistent.sql both
-- assume when they order/lag() by event_sequence. It's not redundant with
-- gold.yml's not_null test on event_sequence: a value can be non-null and
-- still be wrong (duplicated, skipped, or not matching this model's own
-- row_number()-style counting) - only recomputing "what a dense 1..N
-- sequence per record_token actually looks like" and diffing against the
-- stored values catches that.
--
-- Recomputes the expected sequence independently via row_number() (not by
-- re-reading record_lineage_event.sql's own coalesce(...)+1 Jinja logic)
-- ordered the same way the model's own last_logged CTE picks "the most
-- recent prior row" - by event_sequence itself, which is intentional: this
-- test isn't proving event_sequence is consistent with some OTHER
-- ordering (that would be circular, since event_sequence is meant to BE
-- the record_token's authoritative order), it's proving the values
-- actually appended really do form a dense, gapless, duplicate-free
-- sequence.

with recomputed as (

    select
        record_token,
        event_sequence as stored_event_sequence,
        row_number() over (
            partition by record_token
            order by event_sequence
        ) as expected_event_sequence
    from {{ ref('record_lineage_event') }}

)

select *
from recomputed
where stored_event_sequence is distinct from expected_event_sequence
