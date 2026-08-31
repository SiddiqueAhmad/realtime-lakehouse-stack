#!/usr/bin/env python3
"""
Scenario 16: allocator/ledger reconciliation (issue #11).

Proves the repair pass (infra-setup/scripts/lineage_ledger_reconciliation.py)
actually closes the gap reliability-tests/15_lineage_allocator_atomicity.md's
check 4 characterizes: an allocation that commits in Postgres with no
corresponding DuckLake ledger row ever landing.

WHY THIS DOESN'T GO THROUGH A REAL `dbt run`: reproducing the gap through
the actual pipeline would mean making `record_lineage_event`'s own INSERT
fail (or the process die) AFTER `next_event_sequence_if_new()` has already
committed its allocation, deterministically, in CI, without corrupting
other scenarios' fixture data or leaving the DuckLake catalog in a
half-built state other scenarios depend on. That's fragile by nature (it
needs to break the pipeline mid-flight, on purpose, exactly once). Scenario
15 already established the precedent for testing this mechanism directly
against its real, unmodified building blocks rather than through a full
`dbt run` - this scenario does the same: it calls the exact same allocator
SQL (`lineage_seq_udf._ALLOCATE_IF_NEW`) and the exact same DuckLake
connection helper (`dq.connect()`) real production code uses, just without
`dbt` in between, and simulates the missing INSERT the same way scenario
15's check 4 does - by simply not performing one.

Uses dedicated, uuid4-based synthetic record_token values (prefixed
"scenario16-"), which cannot collide with a real record_token (an HMAC
over actual entity primary keys) or with scenario 14/15's own values, so
this can run anywhere in the workflow relative to those.

Checks:
  1. An orphaned allocation (allocated in Postgres, no ledger row) is
     detected and repaired by one reconciliation pass: the ledger row is
     created, with every field matching exactly what was staged at
     allocation time, at the ORIGINAL event_sequence (not a freshly
     allocated one).
  2. Running reconciliation again is a true no-op: no duplicate row, no
     error, nothing left to repair.
  3. A second, later orphan for the SAME record_token (a genuine decision
     transition) is independently detected and repaired without disturbing
     the first repair, and the resulting sequence is dense - {1, 2}, not
     {1, 3} or {2} - proving the outbox's per-event_sequence design (not a
     single latest-allocation row) survives more than one orphan per
     record_token over time.

Usage: lineage_ledger_reconciliation_test.py
Exit 0 on success, exit 1 if any check finds incorrect behavior.
"""

import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "warehouse", "duckdb_plugins"))

import dq  # noqa: E402
import lineage_ledger_reconciliation as reconciler  # noqa: E402
import lineage_seq_udf as alloc  # noqa: E402


def _ensure_ddl():
    conn = alloc._connect()
    conn.autocommit = True
    with conn.cursor() as cur:
        try:
            cur.execute(alloc._DDL)
        except Exception:
            pass
    conn.close()


def _allocate_orphan(record_token: str, decision_fingerprint: str, payload: dict) -> int:
    """Calls the real allocator SQL directly (same statement
    next_event_sequence_if_new() runs) and deliberately does NOT insert
    anything into gold.record_lineage_event afterward - the exact "allocate
    commits, ledger INSERT never happens" gap this scenario exists to
    close. Returns the allocated event_sequence."""
    conn = alloc._connect()
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            alloc._ALLOCATE_IF_NEW,
            {
                "record_token": record_token,
                "decision_fingerprint": decision_fingerprint,
                "payload": json.dumps(payload),
            },
        )
        row = cur.fetchone()
    conn.close()
    if row is None:
        raise AssertionError(f"setup: expected allocation for {record_token}/{decision_fingerprint} to succeed")
    return row[0]


def _fake_payload(**overrides) -> dict:
    base = {
        "dataset": "diagnoses",
        "source_event_id": f"evt_scenario16_{uuid.uuid4()}",
        "pipeline_run_id": "run_scenario16_synthetic",
        "cdc_operation": "c",
        "quality_status": "FAIL",
        "failed_checks": "referential_integrity",
        "is_trusted": False,
        "is_quarantined": True,
        "previous_decision_fingerprint": None,
        "decision_transition": "(new) -> FAIL/quarantined",
        "logged_at": "2026-08-30 12:00:00.000000",
    }
    base.update(overrides)
    return base


def _ledger_row(duck_con, record_token: str, event_sequence: int):
    cols = (
        "dataset, record_token, ledger_key, event_sequence, decision_fingerprint, "
        "previous_decision_fingerprint, decision_transition, source_event_id, pipeline_run_id, "
        "cdc_operation, quality_status, failed_checks, is_trusted, is_quarantined, logged_at"
    )
    row = duck_con.execute(
        f"SELECT {cols} FROM gold.record_lineage_event WHERE record_token = ? AND event_sequence = ?",
        [record_token, event_sequence],
    ).fetchone()
    if row is None:
        return None
    return dict(zip([c.strip() for c in cols.split(",")], row))


def check_orphan_detected_and_repaired():
    record_token = f"scenario16-{uuid.uuid4()}"
    fingerprint = "fp-scenario16-A"
    payload = _fake_payload()

    seq = _allocate_orphan(record_token, fingerprint, payload)
    if seq != 1:
        raise AssertionError(f"check 1 setup: expected first allocation to get event_sequence=1, got {seq}")

    pg_conn = alloc._connect()
    pg_conn.autocommit = True
    duck_con = dq.connect()

    before = _ledger_row(duck_con, record_token, 1)
    if before is not None:
        raise AssertionError(f"check 1 setup: expected NO ledger row before reconciliation, found {before}")

    summary = reconciler.reconcile(pg_conn, duck_con)
    if summary["repaired"] < 1 or summary["failed"]:
        raise AssertionError(f"check 1: expected at least 1 repair and 0 failures, got summary={summary}")

    after = _ledger_row(duck_con, record_token, 1)
    if after is None:
        raise AssertionError("check 1: expected a ledger row to exist after reconciliation, found none")

    expected = {
        "dataset": payload["dataset"],
        "record_token": record_token,
        "ledger_key": f"{record_token}:1",
        "event_sequence": 1,
        "decision_fingerprint": fingerprint,
        "previous_decision_fingerprint": payload["previous_decision_fingerprint"],
        "decision_transition": payload["decision_transition"],
        "source_event_id": payload["source_event_id"],
        "pipeline_run_id": payload["pipeline_run_id"],
        "cdc_operation": payload["cdc_operation"],
        "quality_status": payload["quality_status"],
        "failed_checks": payload["failed_checks"],
        "is_trusted": payload["is_trusted"],
        "is_quarantined": payload["is_quarantined"],
    }
    for key, expected_value in expected.items():
        if after[key] != expected_value:
            raise AssertionError(
                f"check 1: repaired row's {key} = {after[key]!r}, expected {expected_value!r} "
                f"(full row: {after})"
            )
    print(
        "check 1 PASSED: an allocation with no corresponding ledger row was detected and repaired - the "
        "resulting row's every field matches exactly what was staged at allocation time, at the original "
        "event_sequence=1."
    )
    return record_token, pg_conn, duck_con


def check_repair_is_idempotent(record_token, pg_conn, duck_con):
    summary = reconciler.reconcile(pg_conn, duck_con)
    if summary["repaired"] != 0 or summary["failed"]:
        raise AssertionError(f"check 2: expected a second pass to repair nothing new, got summary={summary}")

    dup = duck_con.execute(
        "SELECT count(*) FROM gold.record_lineage_event WHERE record_token = ? AND event_sequence = 1",
        [record_token],
    ).fetchone()[0]
    if dup != 1:
        raise AssertionError(f"check 2: expected exactly 1 row for {record_token}:1 after two reconciliation passes, got {dup}")
    print("check 2 PASSED: re-running reconciliation against an already-repaired row is a true no-op - no duplicate, no error.")


def check_second_orphan_keeps_sequence_dense(record_token, pg_conn, duck_con):
    fingerprint = "fp-scenario16-B"
    payload = _fake_payload(
        quality_status="PASS",
        failed_checks="",
        is_trusted=True,
        is_quarantined=False,
        previous_decision_fingerprint="fp-scenario16-A",
        decision_transition="FAIL/quarantined -> PASS/trusted",
    )
    seq = _allocate_orphan(record_token, fingerprint, payload)
    if seq != 2:
        raise AssertionError(f"check 3 setup: expected the second decision for {record_token} to get event_sequence=2, got {seq}")

    summary = reconciler.reconcile(pg_conn, duck_con)
    if summary["repaired"] < 1 or summary["failed"]:
        raise AssertionError(f"check 3: expected the second orphan to be repaired, got summary={summary}")

    seqs = sorted(
        r[0]
        for r in duck_con.execute(
            "SELECT event_sequence FROM gold.record_lineage_event WHERE record_token = ?",
            [record_token],
        ).fetchall()
    )
    if seqs != [1, 2]:
        raise AssertionError(
            f"check 3: expected a dense sequence {{1, 2}} for {record_token} after both repairs, got {seqs}"
        )
    print(
        "check 3 PASSED: a second, later orphan for the same record_token was independently detected and "
        "repaired without disturbing the first repair - the resulting sequence is dense ({1, 2})."
    )


def main() -> int:
    _ensure_ddl()
    try:
        record_token, pg_conn, duck_con = check_orphan_detected_and_repaired()
        check_repair_is_idempotent(record_token, pg_conn, duck_con)
        check_second_orphan_keeps_sequence_dense(record_token, pg_conn, duck_con)
    except AssertionError as e:
        print(f"::error::scenario 16: {e}", file=sys.stderr)
        return 1
    print(
        "Scenario 16 passed: the allocator/ledger atomicity gap (issue #11) is closed by reconciliation - "
        "an allocation with no corresponding ledger row is detected and repaired from its durably staged "
        "payload, at its original event_sequence, idempotently, and repeated orphans for the same "
        "record_token are each independently recovered without breaking sequence density."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
