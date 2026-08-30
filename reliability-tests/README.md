# Reliability test suite

Fourteen scenarios that exercise the CDC reliability engine
(`warehouse/macros/cdc_reliability.sql`), the data quality gates
(`warehouse/macros/data_quality.sql`), and lineage (`warehouse/macros/lineage.sql`)
against the questions the platform needs to be able to answer:

1. Did we preserve the correct clinical state?
2. Can we prove where that state came from?
3. Can we prove which quality checks it passed?
4. Can we identify who accessed it?
5. Can we replay the pipeline safely?

Each scenario is a small script (or, where the scenario is operational rather
than a single statement, a runbook) plus the expected outcome and a
verification query. They assume the full stack is running
(`cd infra-setup && docker compose up -d`), Debezium has caught up, and
`dbt run --profiles-dir .` (from `warehouse/`) has been executed at least
once after each scenario's setup step.

Scenarios 01–03 are deliberately three separate, narrower claims rather than
one "duplicate/ordering" bucket — they exercise different code paths and a
pipeline can pass one while failing another:

| # | Scenario | Script | Exercises |
|---|---|---|---|
| 1 | Duplicate event (true redelivery) | `01_duplicate_event.sql` | idempotency — the *same* event delivered twice, across two separate merges |
| 2 | Transaction order | `02_transaction_order.sql` | ordering — two *different* events for one key, committed in the same transaction |
| 3 | Out-of-order replay | `03_out_of_order_replay.sql` | ordering — two *different* events delivered out of commit order, across separate deliveries |
| 4 | Deleted diagnosis | `04_deleted_diagnosis.sql` | delete handling / auditability |
| 5 | Invalid patient reference | `05_invalid_patient_reference.sql` | referential integrity gate |
| 6 | Impossible lab value | `06_impossible_lab_value.sql` | clinical plausibility gate |
| 7 | Missing required field | `07_missing_required_field.sql` | completeness gate |
| 8 | Unauthorized PHI access | `08_unauthorized_phi_access.sql` | minimum-necessary access control — **not enforced or exercised since the DuckDB/DuckLake migration**; see the script's own header and `governance/phi_classification.yml`'s KNOWN GAP note |
| 9 | Failed quality gate | (covered by 5–7) | quarantine split |
| 10 | Pipeline replay | `10_pipeline_replay.md` | idempotency at the batch level |
| 11 | Partial CDC failure | `11_partial_cdc_failure.md` | crash recovery |
| 12 | Reprocessing after outage | `12_reprocessing_after_outage.md` | offset resumption + ordering — manual only; see its own file, largely the same claim as 01/03 (which are automated) taken across a full outage/recovery cycle rather than a single insert |
| 13 | Corrected referential integrity | `13_quarantine_correction.sql` | historical lineage — quarantine → trusted transition, both retained |
| 14 | DuckLake concurrent writers | `14_ducklake_concurrent_writers.md` | catalog-level write concurrency — two independent processes racing to log the same pending decisions, specifically `event_sequence`'s safety under real concurrency (not `threads:`, which is a different question — see the file's own explanation) |

Connection defaults used below: Postgres on `localhost:5433` (db=`ehr` for
the OLTP source, db=`warehouse` for the raw CDC landing schema and DuckLake
catalog — user=`testuser`, password=`testpass` for both).

## Running a SQL scenario

```bash
psql "postgresql://testuser:testpass@localhost:5433/ehr" -f reliability-tests/02_transaction_order.sql
# wait for Debezium to stream the change and for a dbt run to process it, then:
python3 infra-setup/scripts/dq.py "SELECT ..."   # see each script's VERIFY block
```

Scenarios that write directly to the raw CDC landing table (01, 03, 05, 13)
run via `psql` against the `warehouse` database instead — see each script's
own `Run:` line.

## What "PASS" means

Each script's `-- EXPECTED` comment says what the reliability/quality layer
should do. A scenario passes if the verification query returns that result —
not if nothing breaks. A pipeline that silently drops or duplicates a row is
a failure even if no error is raised.

## What's actually automated in CI vs. what still needs the live stack

`.github/workflows/ci.yml` runs on every PR and automates:

- `dbt parse` over the whole warehouse project (Jinja/ref/source graph).
- Scenarios 02, 04, 06, 07 against a real Postgres 16 service container
  with the actual `ehr` schema applied, plus `ci_assertions_postgres.sql`
  asserting each one's expected source-side outcome.

It does **not** automate the actual reliability/quality guarantees those
scenarios exist to exercise — dedup, per-key ordering, the quarantine split,
lineage token generation — because those are properties of the
bronze/silver/quality dbt layers running against a live Debezium →
Postgres(raw_cdc) → DuckDB/DuckLake pipeline, which this workflow doesn't
stand up.

`.github/workflows/e2e-pipeline.yml` covers that gap: it runs the actual
`docker compose up` stack (Postgres → Debezium → Postgres raw_cdc → dbt →
DuckDB/DuckLake), runs `dbt run` for real, and asserts every scenario's
outcome by querying bronze/silver/quality/gold tables through DuckDB
(`infra-setup/scripts/dq.py`) — including, now, scenarios **10** (pipeline
replay — content-address `gold.record_lineage` and `gold.record_lineage_event`
with `sha256()` over their actual row data, not just row counts, re-run with
no new writes, assert the hashes are unchanged) and **11** (partial CDC
failure — kill the `debezium` container, write a new row directly to `ehr`
while it's confirmed down, restart it, assert the row lands exactly once
with no gap or duplicate delivery), and **14** (DuckLake concurrent
writers — two independent `dbt run` processes racing to log the same set
of newly-pending decisions into `record_lineage_event`, asserting no
duplicate `event_sequence`/`ledger_key` and no lost decisions; see that
scenario's own file for why this is a genuinely different question from
`threads:`). The workflow also re-runs the full
`dbt test` suite immediately after scenario 13 — not just once at the
start — because scenario 13 is the one case that changes a record's logged
decision without touching that record's own bronze row (see its own file's
comment), which is exactly the condition that let a real `ledger_key`
uniqueness bug through undetected before (see Validation history below).
Scenario 12 remains a manual
runbook only (its claim is largely 01/03's dedup/ordering guarantee taken
across a longer outage, which 01/03 and now 11 already cover from different
angles). Scenario 08 (minimum-necessary access control) is NOT covered —
see that script's own header and `governance/phi_classification.yml`'s
KNOWN GAP note; it was Trino-specific and has no DuckDB equivalent yet, and
closing it is separate, deliberately-deferred follow-up work (real
Postgres-level access control), not something this workflow can assert
around. `RECORD_TOKEN_HMAC_KEY` is generated fresh per run (`openssl rand
-hex 32`) rather than using the insecure dev fallback documented in
`warehouse/duckdb_plugins/lineage_udfs.py`, and no production secret of any
kind is used — every other credential is the synthetic stack's own
hardcoded dev value. On failure, every service's logs (plus dbt's own) are
uploaded as a build artifact, not left to scroll off the console. It's
**not wired to run on every PR** (only `workflow_dispatch` and a nightly
schedule): standing up Postgres and Debezium from cold is slower and has
more failure surface than the fast Postgres-only job above.

**Validation history:** this workflow was rewritten as part of the
DuckDB/DuckLake migration (replacing Trino/Iceberg/Lakekeeper/MinIO) in an
environment with no route to Docker Hub/quay.io or DuckDB's own extension
repository, so none of the new pieces could be exercised end-to-end where
it was written — actual GitHub Actions runs were this migration's first
real validation, and drove out and fixed nine distinct real bugs in turn: a
Debezium Server version too old to bundle its own JDBC sink, a Quarkus
config-escaping crash, an unfiltered internal Debezium topic reaching the
sink, a missing `pandas`/`numpy` dependency, a broken DuckLake catalog
name, an unsupported dbt incremental strategy (`merge`, which dbt-duckdb
doesn't implement), a boolean-formatting mismatch between `dq.py` and this
workflow's assertions, and two confirmed upstream DuckLake bugs
(`duckdb/ducklake#509`, a rename-on-second-build failure, and `#233`, a
concurrent-write crash — see `warehouse/profiles.yml`'s `threads: 1`).
The workflow has since run fully green end-to-end, scenarios 01–13
(08 excepted, as above) — but that's one green run, not a track record;
keep treating individual runs as validation to read the evidence from, not
as proof the pipeline is settled, until it's been promoted to a required
PR check and stayed green there for a while.

A tenth bug turned up on the next pass, in review rather than in CI: the
first version of `record_lineage_event`'s `ledger_key` was
`record_token || ':' || pipeline_run_id`, believed unique because
`record_lineage` has at most one row per `record_token` per run. That's
true, but `pipeline_run_id` is inherited from bronze's *stored* value at
merge time, not recomputed per ledger append — so two ledger entries for
the same `record_token`, logged in two different runs while that record's
own bronze row stays untouched (exactly scenario 13's case: a diagnosis's
decision flips because the *referenced* patient row now exists, not
because the diagnosis's own row changed), could carry the identical
`pipeline_run_id` and collide on `ledger_key`. It went uncaught in the
first green run because `dbt test` only ran once, before any scenario had
executed — scenario 13 always ran after it, so the `unique` test on
`ledger_key` never saw the collision it would have flagged. Fixed by
giving the ledger its own `event_sequence` counter (independent of both
`pipeline_run_id` and wall-clock `logged_at` — see
`record_lineage_event.sql`'s comment) and adding a `dbt test` re-run
immediately after scenario 13 specifically so this class of bug can't hide
behind "the one scenario that would catch it just wasn't re-tested."

The DuckLake concurrent-write crash cited above (`duckdb/ducklake#233`)
was re-tested directly rather than left as a stale citation once that
upstream issue closed: `warehouse/profiles.yml`'s `threads` was flipped
back to 4 and the real e2e pipeline run three times. Two runs passed
clean; the third crashed with the identical signature as the original
report (`Segmentation fault (core dumped)`, exit 139, on two different
models writing the DuckLake catalog concurrently) — see
`warehouse/profiles.yml`'s own comment for the three run IDs. So the
honest, current, re-verified answer is **intermittent, not fixed**:
`threads: 1` stays required. That finding also exposed a second,
previously-unstated gap this project's own docs were conflating:
`threads:` (intra-invocation parallelism across *different* models, which
is what crashed) has nothing to do with whether `record_lineage_event`'s
own `event_sequence` is safe under two separate `dbt run` *processes*
racing on the *same* model — a genuinely different question `threads:`
can't answer at any value. Scenario 14 is the actual test of that
question.
