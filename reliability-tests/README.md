# Reliability test suite

Twelve scenarios that exercise the CDC reliability engine
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

| # | Scenario | Script | Exercises |
|---|---|---|---|
| 1 | Duplicate patient event | `01_duplicate_patient_event.sql` | idempotency / dedup |
| 2 | Out-of-order lab result | `02_out_of_order_lab_result.sql` | ordering |
| 3 | Duplicate encounter | `03_duplicate_encounter.sql` | idempotency / dedup |
| 4 | Deleted diagnosis | `04_deleted_diagnosis.sql` | delete handling / auditability |
| 5 | Invalid patient reference | `05_invalid_patient_reference.sql` | referential integrity gate |
| 6 | Impossible lab value | `06_impossible_lab_value.sql` | clinical plausibility gate |
| 7 | Missing required field | `07_missing_required_field.sql` | completeness gate |
| 8 | Unauthorized PHI access | `08_unauthorized_phi_access.sql` | minimum-necessary access control |
| 9 | Failed quality gate | (covered by 5–7) | quarantine split |
| 10 | Pipeline replay | `10_pipeline_replay.md` | idempotency at the batch level |
| 11 | Partial CDC failure | `11_partial_cdc_failure.md` | crash recovery |
| 12 | Reprocessing after outage | `12_reprocessing_after_outage.md` | offset resumption + ordering |

Connection defaults used below: Postgres on `localhost:5433`
(db=`ehr`, user=`testuser`, password=`testpass`); Trino on `localhost:8080`
(catalog `iceberg`).

## Running a SQL scenario

```bash
psql "postgresql://testuser:testpass@localhost:5433/ehr" -f reliability-tests/01_duplicate_patient_event.sql
# wait for Debezium to stream the change and for a dbt run to process it, then:
trino --server localhost:8080 --catalog iceberg --execute "..."   # see each script's VERIFY block
```

## What "PASS" means

Each script's `-- EXPECTED` comment says what the reliability/quality layer
should do. A scenario passes if the verification query returns that result —
not if nothing breaks. A pipeline that silently drops or duplicates a row is
a failure even if no error is raised.

## What's actually automated in CI vs. what still needs the live stack

`.github/workflows/ci.yml` runs on every PR and automates:

- `dbt parse` over the whole warehouse project (Jinja/ref/source graph).
- `infra-setup/trino/rules.json` JSON validity.
- Scenarios 01, 03, 04, 06, 07 against a real Postgres 16 service container
  with the actual `ehr` schema applied, plus `ci_assertions_postgres.sql`
  asserting each one's expected source-side outcome.

It does **not** automate the actual reliability/quality guarantees those
scenarios exist to exercise — dedup, per-key ordering, the quarantine split,
lineage token generation — because those are properties of the
bronze/silver/quality dbt layers running against a live Debezium → Iceberg →
Trino pipeline, which this workflow doesn't stand up. Nor does it cover
scenarios 02, 05, 08 (need Trino) or the operational runbooks 10–12 (need
the full `docker compose` stack).

`.github/workflows/e2e-pipeline.yml` covers that gap: it runs the actual
`docker compose up` stack (Postgres → Debezium → Iceberg → dbt → Trino),
waits for Debezium's initial snapshot and scenario 01's update events to
land, runs `dbt run` for real, and asserts scenario 01's outcome by querying
`bronze.br_patients` through Trino — proving the reliability engine, not
just the source write. It's **not wired to run on every PR** (only
`workflow_dispatch` and a nightly schedule): standing up MinIO, Lakekeeper,
Postgres, Debezium, and Trino from cold and waiting on a CDC snapshot is
slow and has more failure surface than the fast Postgres-only job above, and
— since this sandbox has no Docker daemon — it was written and reviewed but
**could not actually be executed here**. Treat its first few real runs as
shakeout, and promote it to a required PR check (and extend it to the
out-of-order/quarantine scenarios) once it's demonstrated stable, rather
than trusting it blind because it parses.
