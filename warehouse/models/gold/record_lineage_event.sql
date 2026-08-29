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

with current_state as (

    select * from {{ ref('record_lineage') }}

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
        row_number() over (
            partition by record_token
            order by logged_at desc, pipeline_run_id desc
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
        l.decision_fingerprint as previous_decision_fingerprint
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
-- exists for any of these rows, so previous_* is null for all of them.
changed as (

    select
        c.*,
        cast(null as varchar) as previous_quality_status,
        cast(null as boolean) as previous_is_trusted,
        cast(null as boolean) as previous_is_quarantined,
        cast(null as varchar) as previous_decision_fingerprint
    from current_state c

)

{% endif %}

select
    dataset,
    record_token,
    record_token || ':' || pipeline_run_id as ledger_key,
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
    coalesce(
        previous_quality_status || '/' ||
            (case when previous_is_trusted then 'trusted' else 'quarantined' end),
        '(new)'
    ) || ' -> ' || quality_status || '/' ||
        (case when is_trusted then 'trusted' else 'quarantined' end) as decision_transition,
    source_event_id,
    pipeline_run_id,
    cdc_operation,
    quality_status,
    failed_checks,
    is_trusted,
    is_quarantined,
    {{ dbt.current_timestamp() }} as logged_at
from changed
