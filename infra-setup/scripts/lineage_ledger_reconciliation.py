#!/usr/bin/env python3
"""
Reconciliation / repair pass for the allocator/ledger atomicity gap (issue
#11): closes the gap left open by `next_event_sequence_if_new()`
(`warehouse/duckdb_plugins/lineage_seq_udf.py`), where the Postgres
allocator's commit and the DuckDB/DuckLake `INSERT` into
`gold.record_lineage_event` are two separate transactions, not one atomic
unit.

WHY RECONCILIATION, NOT TWO-PHASE COMMIT: DuckDB/DuckLake and Postgres are
two independent transactional systems with no distributed-transaction
coordinator between them here. A real cross-system 2PC would need one
(a transaction manager both sides participate in, prepare/commit phases,
recovery of in-doubt transactions) - substantial operational and failure
complexity for a requirement that isn't actually "these two systems must
commit atomically", it's "a committed allocation must never be silently,
permanently unrecoverable". A durable outbox + a detectable invariant +
a repair job gives us exactly that, without coupling the two systems'
transaction managers together.

THE INVARIANT THIS ENFORCES: every row `next_event_sequence_if_new()` has
ever durably allocated (i.e., every row in
`lineage_seq.record_lineage_event_outbox` - see that module's own
docstring for how it gets there, atomically, alongside the allocation
itself) must eventually have exactly one corresponding row in
`gold.record_lineage_event`, keyed on (record_token, event_sequence).

HOW REPAIR WORKS: for every outbox row not yet confirmed committed, check
whether the real ledger already has a matching row.

  - It does (the original dbt run's own INSERT actually landed - the
    common case): mark the outbox row committed_at and move on. This
    module never assumes an INSERT failed just because this pass hasn't
    looked at it yet - only "no matching row exists" means missing.
  - It doesn't: replay the INSERT directly against DuckLake, reconstructing
    the exact row from the outbox's own staged JSON payload (built by
    macros/lineage.sql's record_lineage_event_payload_json() at the moment
    of allocation - NOT recomputed from record_lineage's current state,
    which may have moved on since), preserving the ORIGINAL event_sequence
    the allocator assigned. Preserving that sequence, rather than
    allocating a fresh one, is what keeps
    tests/assert_record_lineage_event_sequence_is_dense_and_unique.sql's
    invariant intact - a repair that landed at a new, later sequence number
    would leave a permanent gap at the original one.

IDEMPOTENT AND CRASH-SAFE BY CONSTRUCTION, not by any special-casing: every
action here is "check the ledger, then act, then mark" - if this script
itself dies at any point (mid-check, mid-insert, mid-mark), the next run
just repeats the same check against the ledger's actual current state.
Re-running this against an already-repaired row finds the row already
present and takes the "mark committed" branch, not the "insert again"
branch - so running it twice, or resuming after a kill, never produces a
duplicate row. This is also why marking committed_at is this script's job
alone, never `record_lineage_event.sql`'s own: a post-hook that marks
"committed" right after the model's INSERT would just move the same
gap-risk one step later (the hook itself could fail to run), for no
benefit - the ledger itself is always the authority on whether a row
landed, so that's what this script checks, not a second bookkeeping flag
that could itself drift from the truth.

CONCURRENT RECONCILIATION WORKERS: "check, then act, then mark" is safe
against a script that dies and gets rerun (above), but NOT by itself safe
against two invocations of THIS script running at the same time - both
could check the same outbox row, both find the ledger row absent, and both
replay the INSERT. `reconcile()` below closes that specific gap by
claiming rows with a real Postgres row lock (`SELECT ... FOR UPDATE SKIP
LOCKED`) inside one transaction spanning the whole pass: a second,
concurrent `reconcile()` call simply gets 0 rows back for whichever ones
the first call already claimed (SKIP LOCKED, not blocked-and-retried) and
moves on cleanly - not a failure, just nothing left for it to do this
pass. This is deliberately a lock, not a third `claimed`/`lease` status
column: this module already has one piece of durable state
(`committed_at`) precisely because a second bookkeeping flag is one more
thing that can drift from the truth (see above) - a transaction-scoped
Postgres lock gives the same exclusivity without adding one.

WHAT ROW-LOCKING THE OUTBOX DOES NOT COVER: a race between THIS script and
the ORIGINAL `dbt run` that allocated a row, not between two reconcilers.
If a `dbt run` building `record_lineage_event` is still mid-flight (has
allocated a decision, but its own `INSERT` into the ledger hasn't
committed yet) at the exact moment this script checks that decision's
ledger row, it will correctly see nothing yet and attempt a replay - and
DuckLake's own optimistic concurrency control, as
`record_lineage_event.sql`'s CONCURRENCY CONTRACT comment already
documents for the dbt-vs-dbt case, operates at the snapshot/file level,
not at the level of "did two transactions' rows carry the same logical
key" - so it would NOT reliably catch two non-overlapping appends of the
same decision as a conflict. Locking the Postgres outbox row can't prevent
this: the actual race is over the DuckDB/DuckLake side, a different
database this script has no lock over. The operational answer is
scheduling discipline, not another lock: run this script strictly BETWEEN
pipeline invocations, never concurrently with an in-flight `dbt run` that
builds `record_lineage_event` - by the time it runs, that run's own
INSERT has either already committed (found present, no replay attempted)
or the run is truly finished/crashed (safe to replay). See
`.github/workflows/e2e-pipeline.yml`'s own reconciliation step for the
pattern: run once, right after `dbt run` completes, not on an independent
schedule that could overlap a live run. A dedicated production
scheduler/orchestrator (cron, Airflow, whatever a real deployment uses)
that enforces this ordering is intentionally out of scope for this
reference stack - track it as a follow-up if this pipeline ever runs
somewhere with real concurrent scheduling.

Usage: lineage_ledger_reconciliation.py [--quiet]
Exit 0 if every outbox row is now confirmed present in the ledger (whether
it needed a repair or not). Exit 1 if at least one row could not be
repaired (prints ::error:: for each, with enough detail to investigate
manually) - this pass is expected to always succeed under normal operation
(the payload it needs is always exactly what's staged); a failure here is
a real, actionable finding, not routine noise.
"""

import argparse
import os
import sys
from datetime import datetime, timezone

import psycopg2

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "warehouse", "duckdb_plugins"))

import dq  # noqa: E402  (see sys.path.insert above)
import lineage_seq_udf as alloc  # noqa: E402

_LOGGED_AT_FORMAT = "%Y-%m-%d %H:%M:%S.%f"  # must match macros/lineage.sql's strftime() format exactly

# FOR UPDATE ... SKIP LOCKED is the claim mechanism a concurrent
# reconciliation worker respects (see module docstring's "CONCURRENT
# RECONCILIATION WORKERS" section): a second, simultaneous caller of
# reconcile() gets back only the rows THIS call hasn't already locked,
# never blocks waiting for them, and never double-processes one. The lock
# is held for the whole pass (see reconcile()'s own transaction handling
# below), not released per-row - acceptable for an occasional repair job,
# not a high-throughput queue.
_SELECT_PENDING_FOR_UPDATE = """
SELECT record_token, event_sequence, decision_fingerprint, payload, allocated_at
FROM lineage_seq.record_lineage_event_outbox
WHERE committed_at IS NULL
ORDER BY allocated_at
FOR UPDATE SKIP LOCKED
"""

_MARK_COMMITTED = """
UPDATE lineage_seq.record_lineage_event_outbox
SET committed_at = now()
WHERE record_token = %(record_token)s AND event_sequence = %(event_sequence)s
"""

_LEDGER_EXISTS = """
SELECT 1 FROM gold.record_lineage_event
WHERE record_token = ? AND event_sequence = ?
"""

_LEDGER_INSERT = """
INSERT INTO gold.record_lineage_event (
    dataset, record_token, ledger_key, event_sequence, decision_fingerprint,
    previous_decision_fingerprint, decision_transition, source_event_id,
    pipeline_run_id, cdc_operation, quality_status, failed_checks,
    is_trusted, is_quarantined, logged_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


class RepairError(Exception):
    """Raised when an outbox row can't be confirmed present after a repair
    attempt - a real finding this script's own exit code needs to surface,
    not something to paper over."""


def _ledger_row_exists(duck_con, record_token: str, event_sequence: int) -> bool:
    return duck_con.execute(_LEDGER_EXISTS, [record_token, event_sequence]).fetchone() is not None


def _replay_insert(duck_con, record_token: str, event_sequence: int, decision_fingerprint: str, payload: dict):
    ledger_key = f"{record_token}:{event_sequence}"
    logged_at = datetime.strptime(payload["logged_at"], _LOGGED_AT_FORMAT)
    duck_con.execute(
        _LEDGER_INSERT,
        [
            payload["dataset"],
            record_token,
            ledger_key,
            event_sequence,
            decision_fingerprint,
            payload["previous_decision_fingerprint"],
            payload["decision_transition"],
            payload["source_event_id"],
            payload["pipeline_run_id"],
            payload["cdc_operation"],
            payload["quality_status"],
            payload["failed_checks"],
            payload["is_trusted"],
            payload["is_quarantined"],
            logged_at,
        ],
    )


def reconcile(pg_conn, duck_con, quiet: bool = False) -> dict:
    """Runs one reconciliation pass. Returns a summary dict (counts +
    outcomes) rather than printing directly, so the CI test script
    (infra-setup/scripts/lineage_ledger_reconciliation_test.py) can call
    this and assert on the result instead of scraping stdout.

    Runs its own Postgres transaction (temporarily overriding whatever
    autocommit setting pg_conn came in with, restored on exit) so the
    claiming SELECT ... FOR UPDATE SKIP LOCKED and every row's outcome
    commit together as one unit - see module docstring's "CONCURRENT
    RECONCILIATION WORKERS" section for why this, not a second status
    column, is what makes two simultaneous callers safe."""
    summary = {
        "pending_examined": 0,
        "already_present": 0,
        "repaired": 0,
        "failed": [],
        "oldest_pending_age_seconds": None,
    }

    prior_autocommit = pg_conn.autocommit
    pg_conn.autocommit = False
    try:
        with pg_conn.cursor() as cur:
            cur.execute(_SELECT_PENDING_FOR_UPDATE)
            pending = cur.fetchall()

        now = datetime.now(timezone.utc)
        for record_token, event_sequence, decision_fingerprint, payload, allocated_at in pending:
            summary["pending_examined"] += 1
            age_seconds = (now - allocated_at).total_seconds()
            if summary["oldest_pending_age_seconds"] is None or age_seconds > summary["oldest_pending_age_seconds"]:
                summary["oldest_pending_age_seconds"] = age_seconds

            try:
                if _ledger_row_exists(duck_con, record_token, event_sequence):
                    summary["already_present"] += 1
                else:
                    _replay_insert(duck_con, record_token, event_sequence, decision_fingerprint, payload)
                    # Re-verify rather than assume the INSERT above landed -
                    # exactly the same "don't trust it, check it" discipline
                    # this whole mechanism exists to apply to the original dbt
                    # run's own INSERT.
                    if not _ledger_row_exists(duck_con, record_token, event_sequence):
                        raise RepairError(
                            f"INSERT for {record_token}:{event_sequence} did not raise but the row still "
                            f"isn't visible afterward"
                        )
                    summary["repaired"] += 1
                    if not quiet:
                        print(
                            f"repaired: {record_token}:{event_sequence} (decision_fingerprint={decision_fingerprint}) "
                            f"- allocated {age_seconds:.1f}s ago, never landed in the ledger, replayed from the "
                            f"staged outbox payload"
                        )

                with pg_conn.cursor() as cur:
                    cur.execute(_MARK_COMMITTED, {"record_token": record_token, "event_sequence": event_sequence})
            except Exception as e:  # noqa: BLE001 - deliberately broad: any failure here is a real, reportable finding
                summary["failed"].append((record_token, event_sequence, str(e)))

        # Commits the claim (releasing the row locks) together with every
        # committed_at update made above, all as one unit - a crash before
        # this point rolls the whole pass back (including the claim itself),
        # which is exactly the "next run just repeats the check" crash-safety
        # property the module docstring describes, now also true for the
        # locking transaction itself.
        pg_conn.commit()
    except Exception:
        pg_conn.rollback()
        raise
    finally:
        pg_conn.autocommit = prior_autocommit

    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="suppress per-row repair lines, print only the summary")
    args = parser.parse_args()

    pg_conn = alloc._connect()
    pg_conn.autocommit = True
    with pg_conn.cursor() as cur:
        try:
            cur.execute(alloc._DDL)
        except (
            psycopg2.errors.DuplicateObject,
            psycopg2.errors.DuplicateSchema,
            psycopg2.errors.DuplicateTable,
            psycopg2.errors.UniqueViolation,
        ):
            # The SAME specific race lineage_seq_udf.py's own initialize()
            # documents and catches this exact way, not a bare `except
            # Exception: pass` - CREATE ... IF NOT EXISTS isn't race-free
            # under concurrent execution (this script may run against a
            # schema/table a real dbt process is creating at the same
            # moment), but a genuine failure here (permission denied,
            # malformed DDL, a connection problem, an incompatible existing
            # table from a real schema migration gone wrong) is exactly the
            # kind of failure this script must NOT silently swallow -
            # letting it propagate and crash the run with a clear traceback
            # is the correct behavior for anything that isn't this specific,
            # already-safe-to-ignore race.
            pass

    duck_con = dq.connect()

    summary = reconcile(pg_conn, duck_con, quiet=args.quiet)

    print(
        f"lineage ledger reconciliation: {summary['pending_examined']} outbox row(s) examined, "
        f"{summary['already_present']} already present in the ledger, {summary['repaired']} repaired, "
        f"{len(summary['failed'])} failed."
    )
    if summary["oldest_pending_age_seconds"] is not None:
        print(f"oldest examined allocation was {summary['oldest_pending_age_seconds']:.1f}s old.")

    if summary["failed"]:
        for record_token, event_sequence, error in summary["failed"]:
            print(
                f"::error::lineage ledger reconciliation: could not repair {record_token}:{event_sequence} - {error}",
                file=sys.stderr,
            )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
