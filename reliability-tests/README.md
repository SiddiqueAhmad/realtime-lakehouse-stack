# Reliability test suite

Thirteen scenarios that exercise the CDC reliability engine
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
| 12 | Reprocessing after outage | `12_reprocessing_after_outage.md` | offset resumption + ordering |
| 13 | Corrected referential integrity | `13_quarantine_correction.sql` | historical lineage — quarantine → trusted transition, both retained |

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
stand up. Nor does it cover the operational runbooks 10–12 (need the full
`docker compose` stack, but not scripted end-to-end even there yet).

`.github/workflows/e2e-pipeline.yml` covers that gap for scenarios 01–07 and
13: it runs the actual `docker compose up` stack (Postgres → Debezium →
Postgres raw_cdc → dbt → DuckDB/DuckLake), runs `dbt run` for real, and
asserts every scenario's outcome by querying bronze/silver/quality tables
through DuckDB (`infra-setup/scripts/dq.py`). Scenario 08 (minimum-necessary
access control) is NOT covered — see that script's own header and
`governance/phi_classification.yml`'s KNOWN GAP note; it was Trino-specific
and has no DuckDB equivalent yet. `RECORD_TOKEN_HMAC_KEY` is generated fresh
per run (`openssl rand -hex 32`) rather than using the insecure dev fallback
documented in `warehouse/duckdb_plugins/lineage_udfs.py`, and no production
secret of any kind is used — every other credential is the synthetic
stack's own hardcoded dev value. On failure, every service's logs (plus
dbt's own) are uploaded as a build artifact, not left to scroll off the
console. It's **not wired to run on every PR** (only `workflow_dispatch` and
a nightly schedule): standing up Postgres and Debezium from cold is slower
and has more failure surface than the fast Postgres-only job above.
Additionally, this workflow was rewritten as part of the DuckDB/DuckLake
migration (replacing Trino/Iceberg/Lakekeeper/MinIO) in an environment with
no route to Docker Hub/quay.io or DuckDB's own extension repository, so
none of the new pieces could be exercised end-to-end where this was
written — actual GitHub Actions runs are this migration's first real
validation, and have already driven out and fixed several wrong
assumptions in turn (a bad Maven coordinate for the JDBC sink jar, then
wrongly assuming the stock image needed no sink jars added at all — a real
run said otherwise: "No Debezium consumer named 'jdbc' is available").
Treat its runs as still-settling validation, not as already-proven, and
promote it to a required PR check (and extend it to the 10–12 runbooks)
once it's demonstrated stable, rather than trusting it
blind because it parses.
