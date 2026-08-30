{{ config(materialized='incremental', incremental_strategy='append', schema='gold', tags=['gold', 'observability']) }}

-- Historical operational lineage / incident timeline: an append-only log of
-- every quality decision gold.record_lineage has ever computed for a
-- record, not just its current one.
--
-- WHY THIS MODEL EXISTS, GIVEN record_lineage ALREADY TRACES A RECORD'S
-- JOURNEY: record_lineage is CURRENT-STATE — one row per record, its most
-- recent decision only. A record that failed a check, sat in quarantine,
-- got corrected at the source, and later passed shows only PASS/trusted
-- there; the earlier FAIL/quarantine episode is simply gone, overwritten
-- the moment bronze re-merges a newer version of the row (see
-- macros/cdc_reliability.sql's merge guard). An incident investigation —
-- "why was this record quarantined at 10:02, given it's trusted now?" —
-- can't be answered from current state alone. This model is the append-only
-- counterpart that retains it:
--
--   run 1: CDC event -> quality decision -> FAIL / quarantined   (logged)
--   run 2: (unrelated record changes; this one's decision is unchanged -> not re-logged)
--   run 3: correction lands -> quality decision -> PASS / trusted (logged)
--
-- HOW: reuses record_lineage (already current-state, already PHI-free) as
-- the source of truth for "what does the record's decision look like right
-- now", and appends a new row only when that decision differs from the
-- last one logged for the same record_token — a change log, not a
-- snapshot-every-run table. The decision can change for two different
-- reasons, both worth capturing: the record's own row changed (a new
-- source_event_id), or a referenced record it depends on changed (e.g. a
-- diagnosis's patient_not_found flips from FAIL to PASS purely because the
-- patient row now exists — the diagnosis's own source_event_id is
-- unchanged). Comparing quality_status/is_trusted/is_quarantined as well as
-- source_event_id catches both.
--
-- KNOWN LIMITATION: this logs one entry per dbt run in which a decision
-- changed, not one entry per underlying CDC event. If a record's decision
-- flips more than once between two dbt runs (e.g. two corrections land
-- before the next run picks either up), only the decision current as of
-- that run is logged — the same current-state-only limit bronze itself has
-- (see macros/cdc_reliability.sql's docstring: bronze is a current-state
-- projection over the append-only raw CDC log, not the raw log itself).
-- Sub-run-granular replay would require rebuilding quality decisions
-- directly off the raw CDC log's full history with point-in-time
-- referential joins, which this repo doesn't attempt yet. What this model
-- does guarantee: every decision *this pipeline has actually computed and
-- exposed downstream* (via record_lineage) is retained, in the order it
-- was computed.
--
-- Deliberately PHI-free, same as record_lineage: only record_token and
-- operational/lineage metadata, safe for the same broad access tier as the
-- other gold observability models.
--
-- decision_fingerprint: a deterministic hash of exactly the fields the
-- `changed` comparison below keys on (record_token, source_event_id,
-- quality_status, failed_checks, is_trusted, is_quarantined). This is not
-- what enforces retry-safety - the `changed` CTE's own IS DISTINCT FROM
-- comparisons do that, independent of pipeline_run_id, so a retry that
-- recomputes an identical decision is already a no-op here. What
-- decision_fingerprint adds is making that invariant visible and testable
-- without having to trace the CTE logic: two consecutive rows for the same
-- record_token must never share a fingerprint (see gold.yml's test), which
-- is a directly checkable restatement of "this model never manufactures
-- duplicate history for an unchanged decision."
--
-- previous_decision_fingerprint / previous_quality_status /
-- previous_is_trusted / previous_is_quarantined / decision_transition:
-- carry the prior logged decision (if any) onto the new row directly, so a
-- state transition like "quarantined -> trusted" is a plain column read,
-- not something every downstream query has to reconstruct with its own
-- LAG()/self-join over this table. Null previous_* means this is the
-- first decision ever logged for the record_token (matches the "(new)"
-- case in decision_transition below), not a missing value.
--
-- event_sequence: this ledger's OWN monotonic counter per record_token (1,
-- 2, 3, ...), assigned here rather than borrowed from logged_at or
-- pipeline_run_id. Both of those look like they'd order/dedupe history
-- correctly and don't: pipeline_run_id is inherited from record_lineage,
-- which inherits it straight from bronze's stored value at merge time (see
-- record_lineage.sql's b.pipeline_run_id) - it names which run last wrote
-- this record's OWN row, not which run logged THIS ledger entry. The
-- referenced-record case two paragraphs up (a diagnosis's decision flips
-- because the patient it references now exists, not because the
-- diagnosis's own row changed) is exactly where that breaks: the
-- diagnosis's bronze row - and so its pipeline_run_id - never changes, so
-- two real, distinct, differently-timed ledger entries for the same
-- record_token could carry the identical pipeline_run_id. logged_at
-- (wall-clock at append time) doesn't have that specific failure mode, but
-- offers no formal uniqueness guarantee either. event_sequence does: it's
-- this model's own counter, incremented once per row this model itself
-- appends for a given record_token, independent of what bronze or the
-- clock are doing.
--
-- CONCURRENCY CONTRACT: event_sequence's own arithmetic (read the current
-- max via last_logged_current, then +1) is only correct under a single
-- serialized writer against this catalog - see README.md's DuckLake
-- concurrency known gap. Two concurrent dbt runs against the same
-- DuckLake catalog could both read the same prior value for a
-- record_token and both compute the same next one; nothing in this model
-- detects or prevents that race. This is safe today because
-- warehouse/profiles.yml pins threads: 1 and nothing else writes to this
-- catalog concurrently - not because DuckLake can't do concurrent writers
-- (it's explicitly designed to, via optimistic concurrency control against
-- its SQL catalog) and not because of any property of this column's own
-- read-then-add-one logic. DuckLake's own conflict-and-retry operates at
-- the storage/snapshot level, and there's no verified guarantee it would
-- catch two writers landing on the same event_sequence value for the same
-- record_token as a conflict. A real concurrent-writer requirement would
-- need either that guarantee explicitly verified, or event_sequence
-- allocation moved to something with actual atomic-increment semantics
-- (a database-native sequence, or a compare-and-swap on a dedicated
-- allocator table) - not an assumption that DuckLake's general
-- concurrent-writer support covers this specific case for free.
--
-- DELETED as a quality_status value: record_lineage deliberately leaves
-- quality_status null for a record whose current bronze row is a delete
-- tombstone (its own docstring: "or neither, if the record was deleted
-- before ever reaching a quality decision") - sl_* is a view filtered to
-- `where not is_deleted`, so a deleted record simply has no row there to
-- join against, for any record's delete, not just a pre-decision one.
-- That's the right current-state answer for record_lineage (there IS no
-- live quality decision for a deleted record), but it's the wrong answer
-- here: decision_fingerprint/decision_transition need a real value to
-- hash and print, and a delete is itself a legitimate, auditable decision
-- to log - arguably the most important one scenario 4 exists to prove
-- ("delete handling / auditability"), not a gap to route around. So this
-- model remaps null-because-deleted to the literal status 'DELETED' right
-- at the source (current_state), rather than threading a null-check
-- through every place quality_status gets used below.
with current_state as (

    select
        * exclude (quality_status),
        case when is_deleted then 'DELETED' else quality_status end as quality_status
    from {{ ref('record_lineage') }}

),

{% if is_incremental() %}

last_logged as (

    select
        record_token,
        quality_status,
        is_trusted,
        is_quarantined,
        source_event_id,
        decision_fingerprint,
        event_sequence,
        row_number() over (
            partition by record_token
            order by event_sequence desc
        ) as _rn
    from {{ this }}

),

last_logged_current as (

    select * from last_logged where _rn = 1

),

changed as (

    select
        c.*,
        l.quality_status       as previous_quality_status,
        l.is_trusted           as previous_is_trusted,
        l.is_quarantined       as previous_is_quarantined,
        l.decision_fingerprint as previous_decision_fingerprint,
        coalesce(l.event_sequence, 0) + 1 as event_sequence
    from current_state c
    left join last_logged_current l on l.record_token = c.record_token
    where l.record_token is null
       or l.quality_status  is distinct from c.quality_status
       or l.is_trusted      is distinct from c.is_trusted
       or l.is_quarantined  is distinct from c.is_quarantined
       or l.source_event_id is distinct from c.source_event_id

)

{% else %}

-- First run: the ledger doesn't exist yet, so there's nothing to diff
-- against. Seed it with every record's current decision — this is the
-- ledger's start-of-history point, not a reconstruction of decisions made
-- before this model was added (those were never durably logged anywhere
-- and can't be recovered; see the limitation above). No prior decision
-- exists for any of these rows, so previous_* is null for all of them, and
-- every row is event_sequence 1 for its record_token (record_lineage has
-- at most one row per record_token, so there's no ordering to get wrong
-- here even before event_sequence exists to enforce it elsewhere).
changed as (

    select
        c.*,
        cast(null as varchar) as previous_quality_status,
        cast(null as boolean) as previous_is_trusted,
        cast(null as boolean) as previous_is_quarantined,
        cast(null as varchar) as previous_decision_fingerprint,
        1 as event_sequence
    from current_state c

)

{% endif %}

select
    dataset,
    record_token,
    record_token || ':' || cast(event_sequence as varchar) as ledger_key,
    event_sequence,
    sha256(
        record_token || ':' ||
        coalesce(source_event_id, '') || ':' ||
        quality_status || ':' ||
        coalesce(failed_checks, '') || ':' ||
        cast(is_trusted as varchar) || ':' ||
        cast(is_quarantined as varchar)
    ) as decision_fingerprint,
    previous_decision_fingerprint,
    -- Human-readable "what changed", read straight off the row instead of
    -- reconstructed by joining this table to itself: "(new)" for a
    -- record_token's first-ever logged decision, otherwise
    -- "<prior status>/<trusted|quarantined> -> <new status>/<trusted|quarantined>".
    -- DELETED is printed bare (no "/trusted"|"/quarantined" suffix) -
    -- is_trusted/is_quarantined are just false/false for a deleted record
    -- (nothing to be trusted or quarantined), so appending either word
    -- would misleadingly imply a quality-gate outcome that was never
    -- computed.
    coalesce(
        case
            when previous_quality_status = 'DELETED' then 'DELETED'
            when previous_quality_status is not null then
                previous_quality_status || '/' ||
                    (case when previous_is_trusted then 'trusted' else 'quarantined' end)
        end,
        '(new)'
    ) || ' -> ' ||
        case
            when quality_status = 'DELETED' then 'DELETED'
            else quality_status || '/' || (case when is_trusted then 'trusted' else 'quarantined' end)
        end as decision_transition,
    source_event_id,
    pipeline_run_id,
    cdc_operation,
    quality_status,
    failed_checks,
    is_trusted,
    is_quarantined,
    {{ dbt.current_timestamp() }} as logged_at
from changed
