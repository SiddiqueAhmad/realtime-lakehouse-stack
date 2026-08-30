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
-- CONCURRENCY CONTRACT, UPDATED after reliability-tests/14_ducklake_concurrent_writers.md
-- confirmed the race for real (e2e-pipeline.yml run 33301445564: two
-- independent `dbt run --select record_lineage_event` processes produced 6
-- duplicate (record_token, event_sequence) pairs): event_sequence used to
-- be computed as plain SQL arithmetic (read the current max via
-- last_logged_current, then +1), which is only correct under a single
-- writer - DuckLake's own optimistic concurrency control (it explicitly
-- supports concurrent writers via OCC against its SQL catalog - this was
-- never a DuckLake limitation) operates at the snapshot/file level, not at
-- the level of "did two transactions' newly-appended rows happen to carry
-- the same logical event_sequence value" - two non-overlapping appends are,
-- from DuckLake's point of view, two entirely uncontested writes, so it
-- does not catch this as a conflict.
--
-- event_sequence is now allocated via next_event_sequence_if_new(record_token,
-- decision_fingerprint), a Python UDF (warehouse/duckdb_plugins/lineage_seq_udf.py)
-- that performs a real atomic check-and-allocate against a dedicated
-- allocator table (lineage_seq.record_lineage_event_seq) in the same
-- Postgres server that backs the DuckLake catalog - reached directly via
-- psycopg2, bypassing DuckDB/DuckLake for this operation so it gets a
-- genuine Postgres row lock, not something DuckLake's snapshot-level OCC
-- has to (and doesn't) catch.
--
-- NOTE: allocating a unique event_sequence per call is necessary but NOT
-- sufficient - a first version of this fix did only that, and the very
-- next real concurrent-writer run caught the gap it left open: both
-- writers still independently concluded (from their own, pre-race
-- snapshot of {{ this }}) that a given decision hadn't been logged yet, so
-- both inserted a row for it - each got its own distinct, non-colliding
-- event_sequence, but the SAME decision was logged twice. The fix folds
-- "is this decision actually new" into the SAME atomic Postgres statement
-- as the allocation (keyed on decision_fingerprint, computed up front via
-- macros/lineage.sql's record_lineage_event_decision_fingerprint() so it's
-- available before, not after, the allocation call) - the race's loser
-- gets NULL back, and `changed`'s outer filter drops that row before it
-- ever reaches the INSERT. See that module's own docstring for the full
-- mechanism and its one documented known limitation (a gap on an aborted
-- DuckDB transaction after a successful allocation).
--
-- IMPORTANT DISTINCTION, corrected after an earlier version of this note
-- got it wrong: this race is NOT what warehouse/profiles.yml's threads: 1
-- protects against. threads: controls INTRA-invocation parallelism - how
-- many DIFFERENT models one `dbt run` process builds concurrently - and
-- dbt's own DAG scheduler already guarantees a single model (this one
-- included) is only ever built once, by one thread, per invocation,
-- regardless of the threads value. The race here needs two separate `dbt
-- run` PROCESSES both building record_lineage_event at the same time,
-- which no threads: setting at any value prevents or causes.
-- reliability-tests/14_ducklake_concurrent_writers.md is this project's
-- actual test of that race (real, independent processes racing to write
-- record_lineage_event) - not threads:, which tests something else
-- entirely (see profiles.yml's own comment on the native crash that DOES
-- reproduce under threads > 1, a separate, lower-level stability question
-- from this one).
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

changed_candidates as (

    select
        c.*,
        l.quality_status       as previous_quality_status,
        l.is_trusted           as previous_is_trusted,
        l.is_quarantined       as previous_is_quarantined,
        l.decision_fingerprint as previous_decision_fingerprint,
        {{ record_lineage_event_decision_fingerprint('c.record_token', 'c.source_event_id', 'c.quality_status', 'c.failed_checks', 'c.is_trusted', 'c.is_quarantined') }} as decision_fingerprint
    from current_state c
    left join last_logged_current l on l.record_token = c.record_token
    where l.record_token is null
       or l.quality_status  is distinct from c.quality_status
       or l.is_trusted      is distinct from c.is_trusted
       or l.is_quarantined  is distinct from c.is_quarantined
       or l.source_event_id is distinct from c.source_event_id

),

-- The WHERE below is what actually enforces "no duplicate decision under
-- concurrent writers" (see the CONCURRENCY CONTRACT comment above):
-- next_event_sequence_if_new() returns NULL exactly when some other writer
-- already logged this record_token's identical decision_fingerprint first
-- - dropping that row here, before it ever reaches this model's own
-- INSERT, is what stops both writers from appending a row for the same
-- decision.
changed as (

    select *
    from (
        select
            *,
            next_event_sequence_if_new(record_token, decision_fingerprint) as event_sequence
        from changed_candidates
    )
    where event_sequence is not null

)

{% else %}

-- First run: the ledger doesn't exist yet, so there's nothing to diff
-- against. Seed it with every record's current decision — this is the
-- ledger's start-of-history point, not a reconstruction of decisions made
-- before this model was added (those were never durably logged anywhere
-- and can't be recovered; see the limitation above). No prior decision
-- exists for any of these rows, so previous_* is null for all of them.
-- event_sequence still goes through the same next_event_sequence_if_new()
-- allocator the incremental branch uses below (see the CONCURRENCY
-- CONTRACT comment above), not a hardcoded 1: the allocator's per-
-- record_token counter starts at zero and has no fingerprint on file yet,
-- so a record_token's first-ever call here already returns 1 — but calling
-- it is what teaches the allocator table that decision has been logged, so
-- the *next* incremental run doesn't treat it as new and duplicate it.
changed_candidates as (

    select
        c.*,
        cast(null as varchar) as previous_quality_status,
        cast(null as boolean) as previous_is_trusted,
        cast(null as boolean) as previous_is_quarantined,
        cast(null as varchar) as previous_decision_fingerprint,
        {{ record_lineage_event_decision_fingerprint('c.record_token', 'c.source_event_id', 'c.quality_status', 'c.failed_checks', 'c.is_trusted', 'c.is_quarantined') }} as decision_fingerprint
    from current_state c

),

changed as (

    select *
    from (
        select
            *,
            next_event_sequence_if_new(record_token, decision_fingerprint) as event_sequence
        from changed_candidates
    )
    where event_sequence is not null

)

{% endif %}

select
    dataset,
    record_token,
    record_token || ':' || cast(event_sequence as varchar) as ledger_key,
    event_sequence,
    -- Computed once, up in changed_candidates (see
    -- macros/lineage.sql's record_lineage_event_decision_fingerprint()) -
    -- not recomputed here - specifically so this column can never drift
    -- from the exact fingerprint value next_event_sequence_if_new() was
    -- called with to decide whether this row is a genuinely new decision.
    decision_fingerprint,
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
