"""
dbt-duckdb plugin: registers next_event_sequence(record_token) as a callable
SQL function on every DuckDB connection dbt opens.

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
correctness bug, not a hypothetical one (6 such pairs, confirmed).

HOW: allocates event_sequence from a dedicated allocator table
(lineage_seq.record_lineage_event_seq) in the SAME Postgres server that
already backs the DuckLake catalog (see profiles.yml's DUCKLAKE_CATALOG_*
env vars) - but reached here via a direct psycopg2 connection, deliberately
bypassing DuckDB/DuckLake entirely for this one operation. `INSERT ... ON
CONFLICT (record_token) DO UPDATE SET next_seq = next_seq + 1 RETURNING
next_seq` is a single atomic Postgres statement: Postgres takes a real row
lock on that record_token's allocator row for the duration of the UPDATE, so
two concurrent callers racing on the same record_token are serialized by
Postgres itself (the second blocks until the first commits, then reads the
first's already-incremented value), and each gets a distinct, correctly
incremented value - exactly the "compare-and-swap on a dedicated allocator
table" record_lineage_event.sql's own docstring calls for as the real fix.

Used identically in BOTH the seed (first-run) and incremental branches of
record_lineage_event.sql, not just the incremental one: the seed branch used
to hardcode `1 as event_sequence` directly, which is what this allocator
also returns for a record_token's first-ever call (its row starts at 0) -
but hardcoding it there instead of allocating it would leave the allocator
table not knowing that value was ever handed out, so the *next* incremental
run would allocate 1 again for the same record_token and silently duplicate
it. Routing both branches through the same allocator keeps the table and
the ledger's actual per-record_token max always in sync by construction.

KNOWN LIMITATION: this allocates atomically but does not participate in
DuckDB's own transaction - if the surrounding `dbt run`'s INSERT into
record_lineage_event fails or is rolled back AFTER this function has already
committed an allocation (autocommit, by design - see below), that allocated
value is spent and will never appear in the ledger, leaving a gap. The
project's own dense/gapless sequence test
(tests/assert_record_lineage_event_sequence_is_dense_and_unique.sql) would
catch that if it ever happened, but it isn't expected to under this
pipeline's normal operation: every workflow run in this repo starts from a
freshly created Postgres database (`docker compose down -v`), so the
allocator table and the ledger are always built up together from empty, and
nothing here does `dbt run --full-refresh` mid-session (which would rebuild
the ledger from nothing while leaving the allocator's counts in place,
reintroducing exactly this kind of mismatch - not attempted here, and would
need the allocator table truncated in step with any future full-refresh of
this model).
"""

import os
import threading
from typing import Any, Dict

import psycopg2
from dbt.adapters.duckdb.plugins import BasePlugin
from duckdb import DuckDBPyConnection

_DDL = """
CREATE SCHEMA IF NOT EXISTS lineage_seq;
CREATE TABLE IF NOT EXISTS lineage_seq.record_lineage_event_seq (
    record_token varchar PRIMARY KEY,
    next_seq bigint NOT NULL DEFAULT 0
);
"""

_ALLOCATE = """
INSERT INTO lineage_seq.record_lineage_event_seq (record_token, next_seq)
VALUES (%s, 1)
ON CONFLICT (record_token) DO UPDATE
    SET next_seq = record_lineage_event_seq.next_seq + 1
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
        # call takes visible to the OTHER process's own connection the
        # instant this call returns, rather than held open until some later,
        # unrelated commit on this same connection.
        self._conn = _connect()
        self._conn.autocommit = True
        with self._conn.cursor() as cur:
            cur.execute(_DDL)
        # Defense in depth, not the primary safety mechanism: the real
        # cross-process guarantee comes from Postgres's own row lock in
        # _ALLOCATE above, which holds regardless of what happens on the
        # DuckDB side. This lock only protects against DuckDB itself
        # invoking this Python UDF from more than one of its own internal
        # worker threads concurrently *within a single query* (independent
        # of dbt's threads: config, which governs cross-MODEL parallelism,
        # not intra-query worker threads) - guarding the one psycopg2
        # connection/cursor this plugin instance holds, which is not
        # safe for concurrent use from multiple threads at once.
        self._lock = threading.Lock()

    def configure_connection(self, conn: DuckDBPyConnection):
        # Belt-and-braces alongside the lock above: force this DuckDB
        # connection itself to execute single-threaded, so the Python UDF
        # below is never even offered to more than one worker thread to
        # begin with.
        conn.execute("PRAGMA threads=1")
        conn.create_function(
            "next_event_sequence",
            self._next_event_sequence,
            ["VARCHAR"],
            "BIGINT",
        )

    def _next_event_sequence(self, record_token: str) -> int:
        with self._lock, self._conn.cursor() as cur:
            cur.execute(_ALLOCATE, (record_token,))
            return cur.fetchone()[0]
