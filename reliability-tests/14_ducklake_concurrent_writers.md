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

**RESOLVED:** the first real run of this scenario failed exactly this way
(6 duplicate `(record_token, event_sequence)` pairs — see
[run 33301445564](https://github.com/SiddiqueAhmad/realtime-lakehouse-stack/actions/runs/33301445564)).
`event_sequence` is now allocated via `next_event_sequence()`, a Python UDF
(`warehouse/duckdb_plugins/lineage_seq_udf.py`) implementing exactly the
compare-and-swap-on-a-dedicated-allocator-table fix named above, against
the same Postgres server that backs the DuckLake catalog. This scenario
stays in the workflow as the standing regression check for that fix, not
as a still-open question.

**Automated as:** the "scenario 14" steps in `.github/workflows/e2e-pipeline.yml`
(near the end of the job). One race, five newly-pending decisions racing
at once — a real signal, not an exhaustive stress matrix (a much larger
sweep across writer counts, e.g. 2/4/8/16+ concurrent writers over many
iterations, would give a stronger statistical answer and is legitimate
follow-up work, not something this single CI step claims to replace).
