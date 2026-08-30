#!/usr/bin/env python3
"""
Scenario 15: direct concurrency tests of the Postgres-backed idempotency
allocator that actually enforces gold.record_lineage_event's concurrency
contract — next_event_sequence_if_new() in
warehouse/duckdb_plugins/lineage_seq_udf.py.

WHY A SEPARATE SCRIPT FROM SCENARIO 14: scenario 14
(reliability-tests/14_ducklake_concurrent_writers.md) proves the race end
to end through two real `dbt run` processes writing the same DuckLake
catalog — the right model for "does this fix work in the actual
pipeline". But it can only ever exercise ONE race shape per CI run (two
writers, one snapshot of pending decisions, all racing on DISTINCT
record_tokens with matching fingerprints), because both writers read the
exact same materialized upstream state at the moment the race starts —
see that scenario's own doc. Two race shapes that scenario cannot produce
through the dbt pipeline at all, plus one failure mode it cannot observe
even if it occurred, are exercised here directly against the allocator
itself (the actual mechanism, not a reimplementation of it — this script
imports and calls the exact same functions/SQL warehouse/duckdb_plugins/
lineage_seq_udf.py runs in production):

  1. SAME record_token, SAME decision_fingerprint, many real concurrent
     OS processes (not just two) — the identical shape scenario 14
     covers, but at higher concurrency for a stronger statistical answer,
     and directly against the allocator rather than inferred from the
     resulting DuckLake table.
  2. SAME record_token, DIFFERENT decision_fingerprints, racing at the
     same instant — a genuine decision *transition* (e.g. quarantine ->
     trusted) being logged by two writers at once. Scenario 14 cannot
     produce this: both its writers always read the identical upstream
     snapshot, so they always agree on the decision. This proves
     next_event_sequence_if_new()'s WHERE ... IS DISTINCT FROM clause
     assigns both callers distinct, non-colliding sequence numbers
     (1 and 2) rather than corrupting the counter or serializing them
     onto the same value.
  3. A stress sweep across several concurrent-writer counts (2/4/8) over
     many fresh record_tokens each, for a statistically stronger signal
     than scenario 14's single 2-writer/5-decision race — see that
     scenario's own doc, which calls this out as legitimate follow-up
     work rather than something its single CI step claims to replace.
  4. The allocator module's own documented KNOWN LIMITATION, made an
     executable, CI-checked characterization instead of only a docstring
     claim: an allocation that commits in Postgres but is never followed
     by the corresponding DuckLake ledger INSERT (the exact shape a
     `dbt run` process dying, or its own INSERT failing, between those
     two steps would produce) leaves that decision permanently
     unretriable — a later call with the identical (record_token,
     decision_fingerprint) returns NULL, exactly as if it had already
     been safely logged. This is EXPECTED, CURRENT, documented behavior
     (see lineage_seq_udf.py's own "KNOWN LIMITATION" section) — this
     test proves it is still true today, not that it's fine. It is
     reported as a warning, not a failure, and the test PASSES when the
     documented gap reproduces exactly as documented; it is meant to
     catch the day someone "fixes" this gap without updating the
     documentation (or reintroduces it after a real fix), not to gate
     merges on an accepted, known limitation.

Independent OS processes throughout (multiprocessing.Process, not
threads), matching scenario 14's own reasoning for why that distinction
matters: this allocator's whole correctness case rests on Postgres's own
cross-CONNECTION row locking, not on anything in-process (see
lineage_seq_udf.py's own docstring on why a threading.Lock alone would be
insufficient).

Uses a dedicated set of synthetic record_token values (uuid4-based,
prefixed "scenario15-"), which can never collide with a real record_token
(an HMAC over actual entity primary keys — see macros/lineage.sql) or
with anything scenario 14 uses, so this can safely run before or after
scenario 14 in the same workflow without disturbing either one's table-
state assertions.

Usage: lineage_allocator_concurrency_test.py
Exit 0 on success (including the expected, documented gap in check 4),
exit 1 if any check finds unexpected/incorrect allocator behavior.
"""

import multiprocessing
import os
import sys
import uuid

# Same mechanism dbt-duckdb's `module_paths: [duckdb_plugins]` uses to make
# this module importable (see warehouse/profiles.yml) - added explicitly
# here since this script isn't invoked through dbt.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "warehouse", "duckdb_plugins"))

import lineage_seq_udf as alloc  # noqa: E402  (see sys.path.insert above)


def _ensure_ddl():
    conn = alloc._connect()
    conn.autocommit = True
    with conn.cursor() as cur:
        try:
            cur.execute(alloc._DDL)
        except Exception:
            # Same broad tolerance lineage_seq_udf.py's own initialize()
            # documents: CREATE ... IF NOT EXISTS is not itself race-free,
            # and this script may run after real dbt processes have
            # already created this schema/table.
            pass
    conn.close()


def _allocate_worker(record_token, decision_fingerprint, barrier, result_queue):
    """Runs in its own OS process. Opens its own real Postgres connection
    (never share one across a fork - psycopg2 connections are not
    fork-safe), waits at the barrier so every worker in this race issues
    its allocate call within microseconds of the others, then reports
    exactly what the allocator returned."""
    conn = alloc._connect()
    conn.autocommit = True
    barrier.wait()
    with conn.cursor() as cur:
        cur.execute(
            alloc._ALLOCATE_IF_NEW,
            {"record_token": record_token, "decision_fingerprint": decision_fingerprint},
        )
        row = cur.fetchone()
    conn.close()
    result_queue.put(row[0] if row is not None else None)


def _race(pairs):
    """pairs: list of (record_token, decision_fingerprint) tuples, one per
    worker. Launches len(pairs) real OS processes, all gated on one shared
    barrier, and returns their next_event_sequence_if_new() results in
    launch order (result order does not imply commit order - the barrier
    only synchronizes when each process ISSUES its call, not which one
    Postgres's row lock lets through first)."""
    ctx = multiprocessing.get_context("spawn")
    barrier = ctx.Barrier(len(pairs))
    result_queue = ctx.Queue()
    procs = [
        ctx.Process(target=_allocate_worker, args=(rt, fp, barrier, result_queue))
        for rt, fp in pairs
    ]
    for p in procs:
        p.start()
    results = [result_queue.get(timeout=30) for _ in procs]
    for p in procs:
        p.join(timeout=30)
        if p.exitcode != 0:
            raise AssertionError(f"allocator worker process exited {p.exitcode} (a crash, not a clean allocate/NULL)")
    return results


def check_same_token_same_decision(n_workers=20):
    """Check 1: N real processes race to log the identical decision for
    the same record_token. Exactly one must win (a real, non-null,
    minimal-value sequence number); everyone else must get NULL - proof
    that raising concurrency well beyond scenario 14's two writers still
    doesn't produce a duplicate decision or a duplicate sequence."""
    record_token = f"scenario15-same-{uuid.uuid4()}"
    fingerprint = "fp-A"
    results = _race([(record_token, fingerprint)] * n_workers)
    non_null = [r for r in results if r is not None]
    if len(non_null) != 1:
        raise AssertionError(
            f"check 1 (same token/same decision, {n_workers} racers): expected exactly 1 winner, got "
            f"{len(non_null)} non-null result(s): {results}"
        )
    if non_null[0] != 1:
        raise AssertionError(
            f"check 1: winner's event_sequence should be 1 for a brand-new record_token, got {non_null[0]}"
        )
    print(f"check 1 PASSED: {n_workers} concurrent processes raced on an identical decision for one "
          f"record_token - exactly 1 winner (event_sequence={non_null[0]}), {n_workers - 1} correctly NULL.")


def check_same_token_different_decisions():
    """Check 2: two real processes race on the SAME record_token but with
    genuinely DIFFERENT decision_fingerprints - the shape scenario 14's
    dbt-run-based setup cannot produce (both its writers always agree on
    the decision, since they read one shared upstream snapshot). Both
    should win, with distinct, sequential event_sequence values - not the
    same value twice, and not one silently dropped."""
    record_token = f"scenario15-diff-{uuid.uuid4()}"
    results = _race([(record_token, "fp-X"), (record_token, "fp-Y")])
    if any(r is None for r in results):
        raise AssertionError(
            f"check 2 (same token, different decisions): expected both callers to win (different "
            f"decision_fingerprints are never the same decision, so neither should ever be suppressed "
            f"as a duplicate), got {results}"
        )
    if sorted(results) != [1, 2]:
        raise AssertionError(
            f"check 2: expected event_sequence values {{1, 2}} (whichever writer's transition landed "
            f"first gets 1, the other gets 2), got {results} - a repeated or skipped value here means "
            f"next_event_sequence_if_new()'s counter was corrupted by this race, not just its "
            f"duplicate-decision check."
        )
    print(f"check 2 PASSED: two concurrent, genuinely different decisions for the same record_token both "
          f"logged, with sequential event_sequence values {sorted(results)} - no corruption, no lost transition.")


def check_stress_sweep(writer_counts=(2, 4, 8), iterations=25):
    """Check 3: statistical breadth scenario 14's own doc calls out as
    legitimate follow-up work - the same same-token/same-decision race as
    check 1, repeated many times at several writer counts, each iteration
    on a fresh record_token (so iterations never contend with each other -
    isolating "does raising writer count ever let two writers both win"
    from "do unrelated record_tokens ever cross-contaminate each other's
    allocation", which the next assertion checks directly)."""
    total = 0
    for n in writer_counts:
        for _ in range(iterations):
            record_token = f"scenario15-stress-{n}-{uuid.uuid4()}"
            results = _race([(record_token, "fp-stress")] * n)
            non_null = [r for r in results if r is not None]
            if len(non_null) != 1 or non_null[0] != 1:
                raise AssertionError(
                    f"check 3 (stress, {n} writers): expected exactly 1 winner with event_sequence=1 "
                    f"for record_token={record_token}, got {results}"
                )
            total += 1
    print(f"check 3 PASSED: {total} same-token/same-decision races across writer counts {writer_counts} "
          f"({iterations} fresh record_tokens each) - every single one had exactly 1 winner.")

    # One more angle from the review this generalizes: concurrent writers
    # racing on DIFFERENT record_tokens at the same instant must not
    # cross-contaminate each other's allocation (e.g. two distinct tokens
    # both landing on next_seq=1 is CORRECT - each token's counter is
    # independent - but a shared/serialized result here would indicate the
    # allocator is accidentally serializing unrelated tokens through one
    # lock instead of Postgres's real per-row locking).
    max_n = max(writer_counts)
    pairs = [(f"scenario15-isolation-{uuid.uuid4()}", "fp-isolation") for _ in range(max_n)]
    results = _race(pairs)
    if results != [1] * max_n:
        raise AssertionError(
            f"check 3b (cross-token isolation, {max_n} distinct record_tokens racing at once): expected "
            f"every one of them to win with event_sequence=1 (independent tokens must not contend with "
            f"each other), got {results}"
        )
    print(f"check 3b PASSED: {max_n} DISTINCT record_tokens allocated concurrently, each independently "
          f"got event_sequence=1 - no cross-token contention/corruption.")


def check_allocation_without_ledger_insert_gap():
    """Check 4: characterizes (does NOT fix) the allocator module's own
    documented KNOWN LIMITATION. See this script's module docstring, item
    4, for the full reasoning. This check PASSES when the documented gap
    is confirmed still present and behaving exactly as documented - it
    exists to keep that claim honest and CI-checked, not to imply the gap
    is acceptable to ignore."""
    record_token = f"scenario15-gap-{uuid.uuid4()}"
    fingerprint = "fp-Z"

    first = _race([(record_token, fingerprint)])[0]
    if first != 1:
        raise AssertionError(f"check 4 setup: expected the first allocation to succeed with event_sequence=1, got {first}")

    # No DuckLake/ledger INSERT happens here at all - this line IS the
    # simulation of "the surrounding dbt run's own INSERT into
    # record_lineage_event failed or never ran after the allocator above
    # already committed", the exact gap lineage_seq_udf.py documents. A
    # real retry (e.g. the next scheduled `dbt run`) would call the
    # allocator again with this same (record_token, decision_fingerprint).
    retry = _race([(record_token, fingerprint)])[0]

    if retry is not None:
        raise AssertionError(
            f"check 4: expected a retry after a phantom allocation to be suppressed (NULL) per the "
            f"documented KNOWN LIMITATION in lineage_seq_udf.py, but got event_sequence={retry} instead "
            f"- either the allocator's behavior changed (update this test AND that module's docstring "
            f"together) or something else is wrong."
        )
    print(
        "check 4 PASSED (confirms a KNOWN, ACCEPTED limitation - not a clean result): an allocation that "
        "commits in Postgres with no corresponding DuckLake ledger row ever landing leaves a retry for "
        "the identical decision permanently suppressed (NULL) - reproduces lineage_seq_udf.py's own "
        "documented gap exactly. This is not caught as a bug by this scenario; it is tracked as an "
        "architectural limitation the pipeline currently accepts (see that module's KNOWN LIMITATION "
        "section and README.md's known-gaps section for why: every workflow run starts from a fresh "
        "Postgres database, so this pipeline never actually exercises the full-refresh-after-partial-"
        "failure scenario that would surface it in practice today)."
    )


def main() -> int:
    _ensure_ddl()
    checks = [
        check_same_token_same_decision,
        check_same_token_different_decisions,
        check_stress_sweep,
        check_allocation_without_ledger_insert_gap,
    ]
    for check in checks:
        try:
            check()
        except AssertionError as e:
            print(f"::error::scenario 15: {e}", file=sys.stderr)
            return 1
    print("Scenario 15 passed: the lineage allocator (next_event_sequence_if_new) correctly serializes "
          "same-decision races at higher concurrency than scenario 14 exercises, correctly allocates "
          "distinct sequence numbers for genuinely different decisions racing on the same record_token, "
          "does not cross-contaminate unrelated record_tokens under concurrent load, and its one "
          "documented allocation-without-ledger-insert gap still reproduces exactly as documented.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
