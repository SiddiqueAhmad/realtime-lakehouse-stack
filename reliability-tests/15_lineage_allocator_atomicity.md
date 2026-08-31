# Scenario 15: lineage allocator concurrency and its atomicity gap

**Question:** scenario 14 proves the fix for `gold.record_lineage_event`'s
concurrency race works end to end, through two real `dbt run` processes.
But it can only ever exercise *one* race shape per run — both writers
always read the exact same materialized upstream snapshot, so they always
agree on the decision being logged (see `14_ducklake_concurrent_writers.md`'s
own "Setup" section). This scenario asks the questions scenario 14's setup
structurally cannot: does the actual mechanism behind that fix —
`next_event_sequence_if_new(record_token, decision_fingerprint)`
(`warehouse/duckdb_plugins/lineage_seq_udf.py`) — hold up at higher
concurrency, when two writers race on a genuine decision *transition*
(different fingerprints, not the same one), and under sustained load
across many writer counts? And separately: is that module's own documented
"KNOWN LIMITATION" (an allocation that commits in Postgres but is never
followed by the corresponding DuckLake ledger insert) still real, exactly
as documented, or has it silently drifted?

## Why this is a different question from scenario 14

Scenario 14 goes through the real pipeline: `dbt run` builds
`record_lineage_event`, which calls the allocator once per candidate
decision. That's the right test for "does this work in the actual
system" — but it means every decision both of scenario 14's writers race
on is identical (same `record_token`, same `decision_fingerprint`),
because both read one shared, already-materialized upstream table. A real
decision *transition* racing against itself — writer A logging
"quarantined" for a record_token at the same instant writer B logs
"trusted" for that same record_token, because a correction landed between
the two writers' upstream reads — is a real shape this pipeline can
produce in production (see scenario 13's quarantine → trusted correction,
just concurrent instead of sequential) but not one scenario 14's own setup
can reproduce through two full `dbt run` processes without deliberately
racing a data mutation against the writers themselves, which would be
timing-dependent and flaky as a CI check.

This scenario tests the allocator directly instead — calling the exact
same Python module and SQL scenario 14's own fix depends on
(`lineage_seq_udf._connect()`, `_DDL`, `_ALLOCATE_IF_NEW`), from real,
independent OS processes (not threads — matching scenario 14's own
reasoning: this allocator's correctness rests on Postgres's own
cross-*connection* row locking, not anything in-process), with full
control over which `record_token`/`decision_fingerprint` pairs race.

## Setup

None beyond Postgres being up — this scenario doesn't touch DuckDB,
DuckLake, or dbt at all. It runs the identical allocator DDL
(`CREATE SCHEMA/TABLE IF NOT EXISTS lineage_seq...`) against the same
Postgres server the DuckLake catalog uses, and allocates against
dedicated, `uuid4`-based synthetic `record_token` values (prefixed
`scenario15-...`) that cannot collide with any real record_token (an HMAC
over actual entity primary keys — see `macros/lineage.sql`) or with
anything scenario 14 uses — so this scenario can run before or after
scenario 14 in the same workflow without disturbing either one.

## Checks

1. **Same `record_token`, same `decision_fingerprint`, many racers.** The
   same race shape as scenario 14, at higher concurrency (20 real
   processes, not 2) and asserted directly against the allocator: exactly
   one call must return a real sequence number; every other call must
   return `NULL`.
2. **Same `record_token`, DIFFERENT `decision_fingerprint`s, racing at the
   same instant** — the shape scenario 14 cannot produce. Both calls must
   succeed, with distinct, sequential `event_sequence` values (`{1, 2}`,
   in whichever order Postgres's row lock actually serializes them) — not
   the same value twice, and not one silently dropped.
3. **Stress sweep**: the same same-token/same-decision race as check 1,
   repeated many times (25 iterations) at several writer counts (2, 4, 8),
   each iteration on its own fresh `record_token` — the broader
   statistical sweep `14_ducklake_concurrent_writers.md`'s own doc
   explicitly calls out as legitimate follow-up work beyond its single
   2-writer/5-decision race. Plus one cross-token isolation check: several
   *distinct* `record_token`s allocated concurrently must each
   independently succeed with `event_sequence = 1` — proving the
   allocator's locking is scoped per-`record_token` (Postgres's real
   per-row lock), not accidentally serializing unrelated tokens through
   one shared lock.
4. **The allocation-without-ledger-insert gap.** The allocator's Postgres
   commit and the DuckDB ledger `INSERT` are two separate transactions, not
   one atomic unit, so a `dbt run` that dies (or whose own `INSERT` fails)
   *after* the allocator has already committed leaves that decision
   allocated-but-never-logged, and a later retry with the identical
   `(record_token, decision_fingerprint)` finds the same fingerprint
   already on file and gets `NULL` back, exactly as if it had already been
   safely logged. This check reproduces that exact sequence directly
   (allocate once, simulate the missing ledger insert by simply not
   performing one, then allocate again with the identical pair) and
   asserts the second call returns `NULL`.

   **This check is a characterization of the allocator's own
   retry-suppression behavior, not of an open bug** — issue #11's fix
   (see below) closed the actual failure mode (a lost lineage event no
   retry could recover) without touching this suppression logic at all,
   since it's the same "is this decision actually new" check that stops
   duplicate decisions under concurrency in checks 1–3 above. It exists to
   keep that specific behavior honest and CI-checked — it *passes* when
   the suppression reproduces exactly as documented, and would *fail*
   (catching drift either direction) if it ever silently changed.

   **Issue #11 (closed): what makes that `NULL` recoverable now.** The
   same atomic Postgres statement that allocates the sequence number also
   durably stages the full row that decision's ledger `INSERT` would have
   written, into `lineage_seq.record_lineage_event_outbox` (see
   `lineage_seq_udf.py`'s own docstring and
   `macros/lineage.sql`'s `record_lineage_event_payload_json()`). A
   reconciliation pass, `infra-setup/scripts/lineage_ledger_reconciliation.py`,
   detects any outbox row with no matching ledger row and replays the
   `INSERT` from that staged payload, at the ORIGINAL `event_sequence` —
   preserving the dense-sequence invariant
   `tests/assert_record_lineage_event_sequence_is_dense_and_unique.sql`
   enforces. See scenario 16
   (`16_lineage_ledger_reconciliation.md`) for the executable proof of that
   repair. This check's `NULL` result is unchanged — what changed is that
   it's no longer permanent.

## What this scenario does and does not prove

Precisely, not just loosely — a review of PR #10 flagged that "multi-writer
correctness" undersells what's actually two different, narrower claims
plus one still-open question, so state each one exactly:

- **Scenario 14 proves:** end-to-end multi-writer behavior through the
  real pipeline — `dbt` → DuckDB/DuckLake → the `record_lineage_event`
  ledger — via two genuine, independent `dbt run` processes racing to
  write the same catalog.
- **Scenario 15 (this one) proves:** concurrency correctness of the
  Postgres-backed lineage sequence/idempotency allocator
  (`next_event_sequence_if_new`) itself — that it serializes racing
  callers correctly (same decision, different decisions, many writers,
  many unrelated tokens) — exercised directly, never touching
  DuckDB/DuckLake at all. It does not say anything about whether the
  *pipeline* (dbt models, DuckLake's own catalog writes, the native-crash
  risk `warehouse/profiles.yml`'s own `threads: 1` comment documents) is
  safe under concurrency — only that the allocator those pipeline writers
  depend on is.
- **Neither proves:** atomic durability of "allocate, then DuckLake
  `INSERT`" as one transaction — that's still not one atomic unit, and
  check 4 above still characterizes exactly that. What *is* now proven,
  by scenario 16 (`16_lineage_ledger_reconciliation.md`), is the property
  that actually mattered per issue #11: a decision allocated here is never
  permanently lost even when its own `INSERT` doesn't land, because the
  same allocation call durably staged it for reconciliation to replay.

Read scenarios 14 and 15 together, not as substitutes for each other —
and read both alongside that third bullet before calling the lineage
mechanism's concurrency story complete.

**Automated as:** the "scenario 15" step in `.github/workflows/e2e-pipeline.yml`
(`infra-setup/scripts/lineage_allocator_concurrency_test.py`), immediately
after scenario 14. Runs in well under a minute — every check here is a
plain Postgres round trip, no DuckDB/DuckLake/dbt overhead — despite
covering meaningfully more concurrency (a few hundred allocator calls
across all checks combined) than scenario 14's single race.

**Still not covered, and explicitly out of scope here too:** a
same-`record_token`-different-decision race exercised through the *real*
pipeline (two genuine `dbt run` processes, not direct allocator calls) —
would need deliberately racing a source-data mutation against the two
writers' upstream reads, which is inherently timing-dependent and would
make this a flaky CI check rather than a deterministic one. Remains
legitimate follow-up work. (Check 4's atomicity gap is no longer
open-ended follow-up — see scenario 16.)
