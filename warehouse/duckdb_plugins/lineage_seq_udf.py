"""
dbt-duckdb plugin: registers next_event_sequence_if_new(record_token,
decision_fingerprint) as a callable SQL function on every DuckDB connection
dbt opens.

WHY THIS EXISTS: gold.record_lineage_event's per-record_token event_sequence
counter used to be computed in plain SQL as read-current-max-then-+1 (see
that model's own CONCURRENCY CONTRACT comment). That arithmetic is only
correct under a single writer. reliability-tests/14_ducklake_concurrent_writers.md
confirmed the real failure mode with two genuinely concurrent `dbt run`
processes (real e2e-pipeline.yml run 33301445564): both read the same prior
max for a record_token and both compute the same next value, and DuckLake's
own optimistic concurrency control does NOT catch this as a conflict -
DuckLake's OCC operates at the snapshot/file level (did the set of files
this transaction read change under it), not at the level of "did some other
transaction's newly-appended ROW happen to carry the same logical
event_sequence value" - two non-overlapping appends are, from DuckLake's
point of view, two entirely uncontested writes. Both land, and the ledger
silently accumulates duplicate (record_token, event_sequence) pairs - a real
correctness bug, confirmed (6 such pairs in that run).

A FIRST VERSION OF THIS FIX WAS INCOMPLETE, confirmed by that same
scenario's next real run: allocating a genuinely unique event_sequence per
call (see next_event_sequence(), superseded below) does stop the (record_token,
event_sequence) collision, but does NOT stop the model's own `changed` CTE
from logging the SAME decision twice - each writer reads its own snapshot
of {{ this }} at query start, before the other writer's insert has
committed, so both independently conclude "this decision hasn't been logged
yet" and both proceed to insert a row for it, just with two distinct
(and therefore non-colliding) event_sequence values. The real run this
model's own field-level test caught it with: 10 logged decisions where
exactly 5 were expected - not a duplicate-sequence bug, a duplicate-DECISION
bug. Fixing that needs the "is this decision actually new" check itself to
be atomic and shared across writers, not just the counter.

HOW (v2): next_event_sequence_if_new(record_token, decision_fingerprint)
folds BOTH the "is this decision actually new" check and the sequence
allocation into ONE atomic Postgres statement against a dedicated allocator
table (lineage_seq.record_lineage_event_seq, now tracking each
record_token's last-allocated decision_fingerprint alongside its counter) -
reached via a direct psycopg2 connection to the same Postgres server that
already backs the DuckLake catalog, deliberately bypassing DuckDB/DuckLake
entirely for this operation.

    INSERT INTO record_lineage_event_seq (record_token, next_seq, last_decision_fingerprint)
    VALUES (%(rt)s, 1, %(fp)s)
    ON CONFLICT (record_token) DO UPDATE
        SET next_seq = record_lineage_event_seq.next_seq + 1,
            last_decision_fingerprint = %(fp)s
        WHERE record_lineage_event_seq.last_decision_fingerprint IS DISTINCT FROM %(fp)s
    RETURNING next_seq;

Postgres takes a real row lock on the (record_token) row to evaluate the
ON CONFLICT branch, so two concurrent callers for the same record_token are
serialized by Postgres itself - not by anything on the DuckDB/DuckLake
side. Whichever call commits first "wins": it updates last_decision_fingerprint
to this decision's fingerprint and gets back a fresh, real event_sequence.
The second call (blocked on the row lock until the first commits, thanks to
autocommit) then re-evaluates the UPDATE's WHERE clause against the
fingerprint the winner just wrote - which now equals its own fingerprint,
since both writers are racing to log the identical decision - so the WHERE
is false, Postgres's own documented "ON CONFLICT DO UPDATE ... WHERE"
behavior is to touch nothing and return no row, and this function returns
None (SQL NULL) to the loser. The model filters those NULLs out before its
final INSERT, so only ONE row is ever appended for a given (record_token,
decision_fingerprint) pair, regardless of how many writers raced on it -
this is what actually fixes the duplicate-decision bug the first version
of this function left open, not just the duplicate-event_sequence one.

A genuinely NEW decision for a record_token that already has a DIFFERENT
last_decision_fingerprint on file (a real transition, e.g. scenario 13's
quarantine -> trusted correction) hits the same WHERE clause, finds it
true, and proceeds normally - this mechanism only suppresses re-logging the
literal same decision twice, exactly the retry-safety property this
model's docstring already claims record_lineage_event has, now made safe
under real concurrent writers too, not just retries of a single writer.

KNOWN LIMITATION: this allocates/records atomically but does not
participate in DuckDB's own transaction - if the surrounding `dbt run`'s
INSERT into record_lineage_event fails or is rolled back AFTER this
function has already committed a "new decision" allocation (autocommit, by
design - see below), that decision is marked as logged in the allocator
table but never actually appears in the ledger, and will never be retried
(the allocator would report it as already-logged on the next run). Not
expected under this pipeline's normal operation: every workflow run in this
repo starts from a freshly created Postgres database (`docker compose
down -v`), so the allocator table and the ledger are always built up
together from empty, and nothing here does `dbt run --full-refresh`
mid-session (which would rebuild the ledger from nothing while leaving the
allocator's state in place, reintroducing exactly this kind of mismatch -
not attempted here, and would need the allocator table truncated in step
with any future full-refresh of this model).

REAL RUN CAUGHT ONE MORE THING before this was even exercised under
concurrency: e2e-pipeline.yml run 33303628943 failed the very FIRST
single-writer call to this function with "The returned result contained
NULL values, but the 'null_handling' was set to DEFAULT" - DuckDB's
create_function() default null handling filters any row with a NULL
*input* before calling the Python function, and separately forbids the
function from *returning* NULL at all. Returning None for a race's loser
is this function's entire mechanism, so `null_handling=FunctionNullHandling.SPECIAL`
is required at registration (see configure_connection() below), not
optional - without it, this function cannot do what it exists to do.
"""

import os
import threading
from typing import Any, Dict, Optional

import psycopg2
from dbt.adapters.duckdb.plugins import BasePlugin
from duckdb import DuckDBPyConnection
from duckdb.func import FunctionNullHandling

_DDL = """
CREATE SCHEMA IF NOT EXISTS lineage_seq;
CREATE TABLE IF NOT EXISTS lineage_seq.record_lineage_event_seq (
    record_token varchar PRIMARY KEY,
    next_seq bigint NOT NULL DEFAULT 0,
    last_decision_fingerprint varchar
);
"""

# See module docstring for the full mechanism. The ON CONFLICT ... WHERE
# clause is what makes "is this decision actually new" and "allocate the
# next sequence number" a single atomic operation instead of two - a
# concurrent loser's UPDATE simply doesn't match its own WHERE (the winner
# already wrote this exact fingerprint) and RETURNING yields no row.
_ALLOCATE_IF_NEW = """
INSERT INTO lineage_seq.record_lineage_event_seq
    (record_token, next_seq, last_decision_fingerprint)
VALUES (%(record_token)s, 1, %(decision_fingerprint)s)
ON CONFLICT (record_token) DO UPDATE
    SET next_seq = record_lineage_event_seq.next_seq + 1,
        last_decision_fingerprint = %(decision_fingerprint)s
    WHERE record_lineage_event_seq.last_decision_fingerprint
        IS DISTINCT FROM %(decision_fingerprint)s
RETURNING next_seq;
"""


def _connect():
    # Same connection parameters (and same defaults) as profiles.yml's
    # DuckLake catalog attach and infra-setup/scripts/dq.py's _dsn_parts() -
    # this is the identical Postgres server/database, just reached directly
    # via psycopg2 instead of through DuckDB's postgres/ducklake extensions,
    # which is the entire point (see module docstring: real Postgres
    # row-level locking, not DuckLake's snapshot-level conflict resolution).
    return psycopg2.connect(
        dbname=os.environ.get("DUCKLAKE_CATALOG_DB", "warehouse"),
        host=os.environ.get("DUCKLAKE_CATALOG_HOST", "localhost"),
        port=os.environ.get("DUCKLAKE_CATALOG_PORT", "5433"),
        user=os.environ.get("DUCKLAKE_CATALOG_USER", "testuser"),
        password=os.environ.get("DUCKLAKE_CATALOG_PASSWORD", "testpass"),
    )


class Plugin(BasePlugin):
    def initialize(self, plugin_config: Dict[str, Any]):
        # autocommit: each allocation is its own standalone Postgres
        # transaction, committed immediately - what makes the row lock this
        # call takes (and the fingerprint it writes) visible to the OTHER
        # process's own connection the instant this call returns, rather
        # than held open until some later, unrelated commit on this same
        # connection.
        self._conn = _connect()
        self._conn.autocommit = True
        with self._conn.cursor() as cur:
            try:
                cur.execute(_DDL)
            except (
                psycopg2.errors.DuplicateObject,
                psycopg2.errors.DuplicateSchema,
                psycopg2.errors.DuplicateTable,
                psycopg2.errors.UniqueViolation,
            ):
                # Two dbt run processes starting at once (the exact shape
                # scenario 14 exercises) can both run this same "CREATE ...
                # IF NOT EXISTS" DDL concurrently against a schema/table
                # that doesn't exist yet - CREATE ... IF NOT EXISTS is NOT
                # actually race-free under concurrent execution (a
                # documented Postgres gotcha: both sessions can pass the
                # existence check before either commits its own CREATE).
                # Confirmed here directly, not hypothetically, by racing
                # two local processes against a freshly dropped
                # schema/table repeatedly: CREATE SCHEMA IF NOT EXISTS lost
                # this race as a bare UniqueViolation on
                # pg_namespace_nspname_index (not DuplicateSchema, despite
                # what the SQLSTATE tables suggest it "should" raise), and
                # CREATE TABLE IF NOT EXISTS lost it as DuplicateObject -
                # catching all four is deliberately broad, not guesswork:
                # whichever process lost this race, the schema/table exists
                # now either way, and autocommit means this failed
                # statement didn't leave the connection in an
                # aborted-transaction state, so simply proceeding is
                # correct, not a masked error.
                pass
        # Defense in depth, not the primary safety mechanism: the real
        # cross-process guarantee comes from Postgres's own row lock in
        # _ALLOCATE_IF_NEW above, which holds regardless of what happens on
        # the DuckDB side. This lock only protects against DuckDB itself
        # invoking this Python UDF from more than one of its own internal
        # worker threads concurrently *within a single query* (independent
        # of dbt's threads: config, which governs cross-MODEL parallelism,
        # not intra-query worker threads) - guarding the one psycopg2
        # connection/cursor this plugin instance holds, which is not safe
        # for concurrent use from multiple threads at once.
        self._lock = threading.Lock()

    def configure_connection(self, conn: DuckDBPyConnection):
        # Belt-and-braces alongside the lock above: force this DuckDB
        # connection itself to execute single-threaded, so the Python UDF
        # below is never even offered to more than one worker thread to
        # begin with.
        conn.execute("PRAGMA threads=1")
        conn.create_function(
            "next_event_sequence_if_new",
            self._next_event_sequence_if_new,
            ["VARCHAR", "VARCHAR"],
            "BIGINT",
            # DuckDB's DEFAULT null handling (the create_function default)
            # filters any row with a NULL *input* before calling the Python
            # function AND forbids the function from *returning* NULL -
            # confirmed directly by a real e2e-pipeline.yml run
            # (33303628943) failing every single call with "The returned
            # result contained NULL values, but the 'null_handling' was set
            # to DEFAULT" the instant this function first tried to return
            # None for a race's loser. Returning NULL for exactly that case
            # is this function's entire mechanism (see module docstring) -
            # SPECIAL is what DuckDB calls "let the UDF see and return NULL
            # itself", so it's required here, not optional.
            null_handling=FunctionNullHandling.SPECIAL,
            # This function's whole reason to exist is a side effect (an
            # atomic write to Postgres) - telling DuckDB that explicitly
            # stops it from treating repeated identical calls within a
            # query as safe to cache/eliminate/reorder the way a pure
            # function's calls would be.
            side_effects=True,
        )

    def _next_event_sequence_if_new(
        self, record_token: str, decision_fingerprint: str
    ) -> Optional[int]:
        with self._lock, self._conn.cursor() as cur:
            cur.execute(
                _ALLOCATE_IF_NEW,
                {"record_token": record_token, "decision_fingerprint": decision_fingerprint},
            )
            row = cur.fetchone()
            return row[0] if row is not None else None
