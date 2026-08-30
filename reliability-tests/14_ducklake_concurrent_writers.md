# Scenario 14: DuckLake concurrent writers and event_sequence safety

**Question:** if two independent writers commit to the same DuckLake
catalog at the same time, does `gold.record_lineage_event` stay correct —
specifically, can `event_sequence` (its own per-`record_token` counter;
see that model's own docstring) ever be assigned the same value twice?

## Why this is a different question from `threads:`

`warehouse/profiles.yml`'s `threads: 1` is not what this scenario tests,
and — after an earlier version of this project's docs got this wrong —
it's worth being precise about why. `threads:` controls **intra-invocation**
parallelism: how many *different* models one `dbt run` process builds
concurrently. dbt's own DAG scheduler already guarantees any single model —
`record_lineage_event` included — is built by exactly one thread, once, per
invocation, no matter what `threads` is set to. Raising `threads` (tested
directly on this project — see `warehouse/profiles.yml`'s own comment and
runs 33300464909/33300714850/33301008146) risks a real, currently
*intermittent* native crash when **different** models write the DuckLake
catalog concurrently — a separate, lower-level stability question from this
one.

This scenario tests something `threads:` has no bearing on at any value:
**two separate `dbt run` processes**, each internally single-threaded,
both racing to build `record_lineage_event` at the same time. That's the
only way `event_sequence`'s read-current-max-then-+1 arithmetic can
actually collide — two processes both reading the same prior value for a
`record_token` and both computing the same next one.

## Setup

1. Insert several new diagnoses (fresh IDs, not used by any other
   scenario) directly into `raw_cdc.diagnoses`, each referencing a
   nonexistent `patient_id` — the same referential-integrity-violation
   shape as scenario 5 — so each gets a genuine new FAIL/quarantined
   decision that has never been logged.
2. Run `dbt run --select br_diagnoses sl_diagnoses trusted_diagnoses
   quarantine_diagnoses record_lineage --profiles-dir .` **once**, as a
   single process, to get bronze/silver/quality/`record_lineage` caught up
   — deliberately *not* including `record_lineage_event` in this step, so
   each new diagnosis's decision is genuinely still unlogged (pending) by
   the time the race starts.

## Race

3. Launch two independent `dbt run --select record_lineage_event
   --profiles-dir .` processes at (as close to) the same instant as the
   shell can manage — real OS processes, not dbt threads within one
   invocation — and let both race to log the same set of pending
   decisions.

## Expected

- Neither process should crash. If one does, that's itself a real finding
  (this project's own re-test already found the underlying DuckLake engine
  can crash intermittently under concurrent writes to different models —
  this scenario checks whether that extends to two writers on the *same*
  model too).
- No duplicate `event_sequence` for any `record_token`:
  ```sql
  SELECT record_token, event_sequence, count(*)
  FROM gold.record_lineage_event
  GROUP BY record_token, event_sequence
  HAVING count(*) > 1;
  -- must return zero rows
  ```
- No duplicate `ledger_key` (the same invariant `gold.yml`'s `unique` test
  checks, but exercised under real concurrency rather than a single
  writer):
  ```sql
  SELECT ledger_key, count(*)
  FROM gold.record_lineage_event
  GROUP BY ledger_key
  HAVING count(*) > 1;
  -- must return zero rows
  ```
- Each newly-inserted diagnosis's decision is logged **exactly once** —
  not zero (both writers somehow missed it) and not more than one
  (duplicated).

If this scenario's assertions fail, that is a confirmed, real answer —
not a hypothetical one — to the question `record_lineage_event.sql`'s own
`CONCURRENCY CONTRACT` comment and `README.md`'s known-gap section raise:
`event_sequence` allocation is not safe under genuinely concurrent
writers and would need a real atomic-increment mechanism (a
database-native sequence, or a compare-and-swap on a dedicated allocator
table) before this pipeline could ever run more than one writer against
the same catalog at a time.

**RESOLVED (in two passes, not one):** the first real run of this scenario
failed exactly this way (6 duplicate `(record_token, event_sequence)`
pairs — see
[run 33301445564](https://github.com/SiddiqueAhmad/realtime-lakehouse-stack/actions/runs/33301445564)).
A first fix allocated a genuinely unique `event_sequence` per call
(`next_event_sequence()`) via a compare-and-swap allocator table, which
stopped the sequence collision — but the *next* real run of this same
scenario caught a second bug that fix left open: both writers still
independently read their own pre-race snapshot of this model's own table
and both concluded a given decision hadn't been logged yet, so both
inserted a row for it (10 logged decisions where exactly 5 were expected —
a duplicate-*decision* bug, not a duplicate-sequence one). `event_sequence`
is now allocated via `next_event_sequence_if_new(record_token,
decision_fingerprint)`, a Python UDF
(`warehouse/duckdb_plugins/lineage_seq_udf.py`) that folds the "is this
decision actually new" check into the SAME atomic Postgres statement as
the allocation, against the same Postgres server that backs the DuckLake
catalog — a race's loser gets `NULL` back and its row is dropped before it
ever reaches this model's `INSERT`. This scenario stays in the workflow as
the standing regression check for that fix, not as a still-open question.

**Automated as:** the "scenario 14" steps in `.github/workflows/e2e-pipeline.yml`
(near the end of the job). One race, five newly-pending decisions racing
at once — a real signal, not an exhaustive stress matrix (a much larger
sweep across writer counts, e.g. 2/4/8/16+ concurrent writers over many
iterations, would give a stronger statistical answer and is legitimate
follow-up work, not something this single CI step claims to replace).

A writer crash (per "Expected" above) hard-fails this step - the assert
step captures both writers' real exit codes via `wait $pid` and treats a
non-zero exit as a required failure, not just a warning, after first
printing the resulting table state as a diagnostic (a crashed writer can
still leave the table looking clean if it dies after its own inserts land,
which is precisely why the crash itself has to fail the run rather than
being inferred from table state).

**What this scenario does and does not prove:** DuckLake's own concurrent-
writer support (its OCC across independent `dbt run` processes appending
to the same catalog) is real and is what makes this scenario's *setup*
safe to run at all. But the actual invariant this scenario's assertions
check - no duplicate `event_sequence`, no duplicate `ledger_key`, no
duplicate/lost decision - is enforced by `next_event_sequence_if_new()`'s
Postgres-backed allocator (`warehouse/duckdb_plugins/lineage_seq_udf.py`),
not by DuckLake itself; DuckLake's catalog-level OCC does not (and isn't
meant to) catch two non-overlapping appends that happen to carry the same
*application-level* value. So scenario 14 is a real test of "two
independent processes can safely race to write the same DuckLake catalog
table" *given* this allocator, not evidence that DuckLake alone enforces
this specific business invariant. Read together with the allocator
module's own docstring (see its "KNOWN LIMITATION" section: the allocator
commits its Postgres allocation and the DuckDB ledger insert as two
separate transactions, not one atomic unit), this scenario is the
regression check for the fix, not a full concurrency qualification suite -
a same-`record_token`-different-decision race, a stress sweep across
higher writer counts, and a test of the allocator's documented
allocate-then-DuckDB-insert-fails gap all remain legitimate, unaddressed
follow-up work.
