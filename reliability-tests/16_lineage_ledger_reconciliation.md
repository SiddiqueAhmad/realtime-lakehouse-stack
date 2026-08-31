# Scenario 16: allocator/ledger reconciliation closes the atomicity gap (issue #11)

**Question:** scenario 15's check 4 characterizes a real gap: the Postgres
allocator (`next_event_sequence_if_new()`,
`warehouse/duckdb_plugins/lineage_seq_udf.py`) can commit an allocation for
a decision whose corresponding `gold.record_lineage_event` `INSERT` never
lands (the surrounding `dbt run` dies, or its own `INSERT` fails), and a
later retry of the identical `(record_token, decision_fingerprint)` is
suppressed (`NULL`), exactly as if it had already been safely logged. Left
alone, that's a lost lineage event no retry can ever recover — issue #11's
stated concern. This scenario asks: does the fix (a durable outbox +
reconciliation pass) actually recover it?

## Why reconciliation, not two-phase commit

DuckDB/DuckLake and Postgres are two independent transactional systems with
no distributed-transaction coordinator between them here. A real 2PC would
need one — a transaction manager both sides participate in, prepare/commit
phases, recovery of in-doubt transactions — substantial operational and
failure complexity for a requirement that isn't actually "these two systems
must commit atomically", it's "a committed allocation must never become
silently, permanently unrecoverable". A durable outbox + a detectable
invariant + a repair job gives exactly that, without coupling the two
systems' transaction managers together. See
`infra-setup/scripts/lineage_ledger_reconciliation.py`'s own module
docstring for the full reasoning.

## How the fix works

The SAME atomic Postgres statement that allocates `event_sequence`
(`lineage_seq_udf.py`'s `_ALLOCATE_IF_NEW`) also stages the exact row
`record_lineage_event.sql` is about to insert — as JSON, built by
`macros/lineage.sql`'s `record_lineage_event_payload_json()`, computed
*before* the allocation call so it can never drift from what the model
would actually write — into a new table,
`lineage_seq.record_lineage_event_outbox`, keyed on
`(record_token, event_sequence)` (not on `record_token` alone, unlike the
counter table: every allocation ever made must stay staged here,
independent of whatever a later, unrelated decision for the same
`record_token` has since done to the counter).

`infra-setup/scripts/lineage_ledger_reconciliation.py` is the repair pass:
for every outbox row not yet confirmed committed, it checks whether the
real ledger already has a matching row.

- **Yes** (the common case — the original `dbt run`'s own `INSERT` landed):
  mark the outbox row committed and move on.
- **No**: replay the `INSERT` directly against DuckLake from the outbox's
  own staged payload, at the ORIGINAL `event_sequence` — never a freshly
  allocated one, which is what keeps
  `tests/assert_record_lineage_event_sequence_is_dense_and_unique.sql`'s
  invariant intact.

Every action is "check the ledger, then act, then mark" — idempotent and
crash-safe by construction, not by special-casing: if the reconciliation
process itself dies at any point, the next run just repeats the same check
against the ledger's actual current state. Re-running it against an
already-repaired row takes the "mark committed" branch, never
"insert again" — so a partial run followed by a full run behaves exactly
like two full runs, which is what checks 1–2 below actually prove (a live
process kill mid-reconciliation isn't separately simulated — see "What this
scenario does and does not prove").

## Setup

None beyond Postgres and DuckDB/DuckLake being up. Like scenario 15, this
doesn't go through a real `dbt run` — it calls the exact same allocator SQL
(`lineage_seq_udf._ALLOCATE_IF_NEW`) and the exact same DuckLake connection
helper (`infra-setup/scripts/dq.py`'s `connect()`) real production code
uses, and simulates the missing ledger `INSERT` the same way scenario 15's
check 4 does — by simply not performing one. Reproducing this gap through
the actual pipeline would mean deliberately breaking `dbt run`'s own
`INSERT` mid-flight, exactly once, without corrupting other scenarios'
fixture data — fragile by nature; testing the mechanism directly against
its real, unmodified building blocks is the same choice scenario 15 already
made for the allocator itself.

Uses dedicated, `uuid4`-based synthetic `record_token` values (prefixed
`scenario16-`), which cannot collide with a real `record_token` (an HMAC
over actual entity primary keys) or with scenario 14/15's own values, so
this scenario can run anywhere in the workflow relative to those.

## Checks

1. **Orphan detected and repaired.** An allocation is made (Postgres
   commits, staging a full synthetic payload into the outbox) and no
   ledger `INSERT` follows. Before reconciliation, `gold.record_lineage_event`
   has no matching row. One reconciliation pass must create it — every
   field must match exactly what was staged at allocation time
   (`dataset`, `source_event_id`, `pipeline_run_id`, `cdc_operation`,
   `quality_status`, `failed_checks`, `is_trusted`, `is_quarantined`,
   `previous_decision_fingerprint`, `decision_transition`, `logged_at`),
   at the original `event_sequence` (1, not a freshly allocated later
   value) and the correct `ledger_key`.
2. **Idempotent repair.** Running reconciliation a second time against the
   now-repaired row must repair nothing new, create no duplicate, and raise
   no error.
3. **Repeated orphans on the same `record_token` stay dense.** A SECOND,
   later decision for the SAME `record_token` (a genuine transition, e.g.
   quarantined → trusted) is allocated and also left un-inserted. Repairing
   it must not disturb the first repair, and the resulting sequence for
   that `record_token` must be exactly `{1, 2}` — proving the outbox's
   per-`event_sequence` design (not a single latest-allocation row per
   `record_token`) correctly survives more than one orphan over time for
   the same record.

## What this scenario does and does not prove

- **Proves:** an allocation with no corresponding ledger row is detected
  and repaired, exactly reconstructed from its durably staged payload, at
  its original sequence position, idempotently, and that this holds for
  more than one orphan on the same `record_token` without breaking
  sequence density.
- **Does not separately prove:** literal process-kill crash-safety of the
  reconciliation script itself (e.g. `SIGKILL` mid-`INSERT`). The design
  argument for that (see "How the fix works" above) is that every step is
  check-before-act and idempotent, so a partial run is equivalent to a
  shorter successful run followed by a normal one — check 2's idempotency
  proof already covers exactly that composition. A literal kill-and-resume
  harness would be testing the OS process model, not this mechanism's own
  logic, and was judged not to add signal beyond check 2.
- **Does not prove:** this scenario doesn't exercise reconciliation being
  run automatically on a schedule or at pipeline startup — it's invoked
  directly here, the same way a production deployment would need to wire
  it in (a periodic job, or a startup check) as an operational decision
  outside this repo's CI, which only proves the mechanism itself is
  correct.

**Automated as:** the "scenario 16" step in `.github/workflows/e2e-pipeline.yml`
(`infra-setup/scripts/lineage_ledger_reconciliation_test.py`), immediately
after scenario 15.
