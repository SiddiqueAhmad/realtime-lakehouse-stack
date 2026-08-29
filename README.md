# 🏥 Realtime Healthcare Data Reliability Platform

**A HIPAA-aligned, real-time healthcare data platform — CDC reliability, data quality, lineage, minimum-necessary access, and AI-readiness, built entirely on open-source components.**

![Architecture](docs/realtime-lakehouse-architecture.png)

> **Diagram is stale as of the DuckDB/DuckLake migration** — it still shows
> Trino/Iceberg/Lakekeeper/MinIO. See "Architecture: DuckDB + DuckLake"
> below for the current shape; regenerating this image is follow-up work.

> **HIPAA-aligned, not "HIPAA compliant."** This repository implements the
> technical controls a HIPAA-regulated data flow needs — PHI classification,
> access control, audit-safe lineage, quality gating, de-identification. It
> is not, and cannot be, a compliance claim on its own: compliance depends on
> the complete administrative, physical, and contractual environment around
> the software, not the software alone. See [`docs/hipaa_alignment.md`](docs/hipaa_alignment.md).
>
> **All data in this repository is synthetic.** No real patient information
> is stored, transmitted, or referenced anywhere in this codebase.

---

## 🚀 Overview

This stack simulates an EHR's operational data flowing through change data
capture into a governed lakehouse:

1. **Postgres (TimescaleDB)** — operational EHR: `Patient → Encounter →
   {Diagnosis, Procedure, LabResult, Observation}`, plus `Provider` and
   `Facility`.
2. **Debezium** — streams row-level changes out of Postgres in real time,
   via its JDBC sink, into a `warehouse.raw_cdc` landing schema (also in
   Postgres — see "Architecture: DuckDB + DuckLake" below).
3. **DuckLake (self-hosted, Postgres-backed catalog)** — immutable,
   versioned raw CDC history, queried through DuckDB.
4. **dbt reliability engine (bronze)** — idempotent, ordering-safe,
   delete-aware CDC processing.
5. **dbt data quality gates (silver → quality)** — completeness, validity,
   referential integrity, and clinical plausibility checks split records
   into **trusted** vs **quarantine**.
6. **De-identification (deid)** — a Safe-Harbor-*style* path to analytics-safe
   data, separate from the PHI-carrying layers.
7. **DuckDB** — query trusted, de-identified, and aggregate data.
8. **Metabase** — BI dashboards on top of the operational Postgres source
   (gold/deid dashboards are a known gap — see "Architecture" below).

## 🧭 The north star

```
HEALTHCARE SOURCE
   PostgreSQL/EHR
        │
       CDC (Debezium)
        │
        ▼
  RAW CDC (warehouse.raw_cdc, Postgres) ── immutable append-only CDC history
        │
        ▼
 RELIABILITY ENGINE  ── dedup / idempotency, ordering, delete handling
   (bronze, macros/cdc_reliability.sql)
        │
        ▼
  DATA QUALITY GATES  ── completeness, validity, referential integrity,
   (silver, macros/data_quality.sql)   clinical plausibility
        │
   ┌────┴────┐
   ▼         ▼
TRUSTED   QUARANTINE
   │
   ▼
DE-IDENTIFICATION (Safe-Harbor-style) ──► deid / gold (aggregate)
   │
   ▼
DuckDB / DuckLake ──► Analytics / AI, under minimum-necessary access*
```
<sub>* not currently enforced at query time — see "Governance & PHI" below.</sub>

Lineage (`record_token`, `source_event_id`, `pipeline_run_id`,
`quality_status`) and access control run through every layer — see
[Governance & PHI](#-governance--phi) below — rather than being bolted on at
the end.

## 🏗️ Domain model

```
Patient
   ├── Encounter
   │      ├── Diagnosis
   │      ├── Procedure
   │      └── (Provider, Facility)
   ├── Medication
   ├── Lab Result
   └── Observation
```

Seeded as synthetic data in `infra-setup/timescale/healthcare.sql`.

## 📚 Layers

| Layer | Location | Purpose |
|---|---|---|
| Raw CDC | `raw.raw_cdc.*` (Postgres, attached read-only into DuckDB) | Immutable event history landed by Debezium's JDBC sink |
| Bronze | `warehouse/models/bronze/` | Reliability engine: dedup, ordering, soft deletes → current state per key |
| Silver | `warehouse/models/silver/` | Data quality gates → `quality_status` + `failed_checks` + lineage |
| Quality | `warehouse/models/quality/` | `trusted_*` / `quarantine_*` split by `quality_status` |
| De-identified | `warehouse/models/deid/` | Safe-Harbor-style transform of trusted data |
| Gold | `warehouse/models/gold/` | Aggregate-only analytics + observability (freshness, CDC lag, volume, quality pass rate) |

## 🦆 Architecture: DuckDB + DuckLake

This stack originally ran on Trino + Apache Iceberg (via a Lakekeeper REST
catalog) + MinIO. It was migrated to DuckDB + [DuckLake](https://ducklake.select/)
to cut the infrastructure down to what this platform actually needs — no
JVM query server, no separate object-store service, no REST catalog service
— while keeping the same reliability/lineage/quality guarantees:

- **DuckDB** replaces Trino as the query/transform engine. It's embedded —
  `dbt-duckdb` opens it directly, no server process to run or wait on.
- **DuckLake** (a DuckDB extension) replaces Iceberg + Lakekeeper: table
  *metadata* (snapshots, schema, file listing) lives transactionally in
  Postgres — the same `db` service already running everything else in this
  stack, in a `warehouse` database — and table *data* is Parquet on local
  disk. That Postgres-backed metadata is what gives multiple DuckDB
  processes real concurrent read/write safety; a bare local `.duckdb` file
  doesn't have that. See `warehouse/profiles.yml`.
- **Debezium's sink** changed from its Iceberg connector to its **JDBC**
  sink, writing straight into `warehouse.raw_cdc.<table>` in Postgres (still
  append-only — see `infra-setup/debezium-server-conf/application.properties`).
  DuckDB reads that schema cross-engine via its `postgres` extension
  (attached read-only as `raw` — see `warehouse/models/sources.yml`).
- **HMAC token generation** (`record_token`/`source_event_id` — see
  `docs/lineage_token_rotation.md`) moved from a Trino SQL function to a
  Python UDF (`warehouse/duckdb_plugins/lineage_udfs.py`), since DuckDB has
  no built-in keyed HMAC. This is a real security improvement, not just a
  compatibility shim: the HMAC key now never gets templated into compiled
  SQL, closing a limitation the Trino version could only document and defer.

**Known gaps from this migration** (both explicit tradeoffs, not oversights):

1. **No enforced access control.** Trino's file-based `rules.json` used to
   mechanically enforce the role → access matrix in
   `governance/phi_classification.yml` at query time. DuckDB is embedded and
   single-process — it has no per-connection/per-role ACL layer. That file
   now documents the intended policy without enforcing it; nothing in this
   stack currently stops a lower-tier query from reading a PHI column. See
   its own KNOWN GAP note. Leading candidate to close this: role-scoped
   Postgres views + real `GRANT`s in front of gold/deid outputs, so a real
   serving layer keeps a testable ACL — not implemented here.
2. **No BI tool wired up to gold/deid.** Metabase has no first-party DuckDB
   driver, so `infra-setup/metabase/setup_metabase.py` only registers the
   operational EHR Postgres connection now, not a warehouse one. Querying
   `gold.*`/`deid.*` today means running `infra-setup/scripts/dq.py`
   directly (see "Quick Start" below) or `dbt show`.

**Validation note:** this migration's network egress policy blocked Docker
image pulls (the new Debezium+JDBC-sink image) and DuckDB's own extension
repository (`ducklake`, `postgres`) where it was written — the actual
JDBC-sink → `raw_cdc` table shape and the `ducklake:` attach syntax could
not be exercised end-to-end there. `dbt parse`/`dbt compile` against a real
`dbt-duckdb` install, and every SQL function used, were checked directly;
what couldn't be checked locally was validated via
`.github/workflows/e2e-pipeline.yml` on a real GitHub Actions runner
instead. See that workflow's own header comment for specifics.

## 📈 Observability

Four gold models answer "is the pipeline healthy?" without exposing any
PHI-classified column — counts, timestamps, and run ids only. Each has a
precise, deliberately-not-interchangeable definition (see each model's own
docstring for the reasoning):

| Model | Answers |
|---|---|
| `gold.cdc_freshness` | For the most-recently-processed event per dataset: how long did it take to land in bronze (`cdc_lag_seconds`), and how long ago was that (`staleness_seconds`)? Both measured from the same row, not two independently-maxed timestamps. |
| `gold.cdc_volume_summary` | Raw CDC event volume split into unique vs. *duplicate* events (a literal redelivery — same natural key **and** LSN — not just "another update"), by operation type, against the current row count, plus each as a rate (`duplicate_rate_pct`/`insert_rate_pct`/`update_rate_pct`/`delete_rate_pct`, summing to ~100%). |
| `gold.data_quality_summary` | Pass/fail record counts per dataset, **per pipeline run** — how did a specific run's batch look. |
| `gold.current_quality_summary` | PASS rate per dataset, **right now** — computed directly off the live silver population, not by summing across runs. |

These read `pipeline_run_id`/`cdc_source_ts_ns`/`_loaded_at` — already
computed once per row by the reliability engine (`macros/cdc_reliability.sql`)
— rather than adding a separate metrics-collection mechanism.

### Operational lineage: "why is this record in the state it's in, right now?"

`gold.record_lineage` traces one record's *current* journey — CDC event →
processing run → quality decision → trusted/quarantine — for the 4 fully
quality-gated entities (patients, encounters, diagnoses, lab_results):

```
Patient record
     │
CDC event (source_event_id: which transaction/LSN produced this version)
     │
Processing (pipeline_run_id: which dbt run merged it into bronze)
     │
Quality decision (quality_status / failed_checks)
     │
 ┌───┴────┐
 ▼        ▼
trusted quarantine   (or neither, if deleted before a decision was made)
```

This is **current-state lineage**: one row per record, reflecting its most
recent quality decision. If a record failed a check, sat in quarantine, was
corrected at the source, and later passed, `record_lineage` shows only the
latter — the earlier quarantine episode isn't retained here. For "what
happened to this record over time, and when," a historical/incident-timeline
model (one row per quality decision, not per record) is future work, not
yet part of this repo.

Keyed on `record_token`, not the natural key — PHI-free, so an analyst or
an AI agent can investigate *why* a record is currently quarantined without
touching a clinical value. Resolving `record_token` back to the underlying
row is a separate, governed lookup gated on its own access tier (see
[Governance & PHI](#-governance--phi) below) — the token itself doesn't
grant that; a `clinical_user`/`data_engineer` still needs to go through
that lookup, not just read the token, to reach the PHI.

### Historical operational lineage: "what happened to this record, and when?"

`gold.record_lineage_event` is the append-only counterpart to
`record_lineage`: every quality decision it has ever computed for a record,
not just the current one. Same 4 entities, same `record_token` key, same
PHI-free boundary — but where `record_lineage` overwrites a record's row in
place as its decision changes, this logs a new row each time it does:

```
run 1: CDC event → quality decision → FAIL / quarantined      (logged)
run 2: (unrelated changes; this record's decision unchanged → not re-logged)
run 3: correction lands → quality decision → PASS / trusted   (logged)
```

That's the "why was this record quarantined at 10:02, even though it's
trusted now?" question `record_lineage` alone can't answer — the earlier
row is still there. A decision can change for two different reasons, both
captured: the record's own CDC event changed, or a record it depends on
did (e.g. a diagnosis's `patient_not_found` check flips from FAIL to PASS
purely because the referenced patient now exists — the diagnosis's own
`source_event_id` never changes).

**Known limitation**, stated up front rather than implied away: this logs
one entry per dbt run in which a decision changed, not one per underlying
CDC event. If a record's decision flips more than once between two runs,
only the decision current as of the later run is logged — the same
current-state limit bronze itself has (see
`macros/cdc_reliability.sql`'s docstring). Reconstructing sub-run-granular
history would mean rebuilding decisions directly off the raw CDC log with
point-in-time referential joins, which this repo doesn't attempt yet. What
it does guarantee: every decision this pipeline has actually computed and
exposed downstream is retained, in the order it was computed — and the
ledger's own start-of-history point is when this model was first built, not
retroactively reconstructed further back.

`reliability-tests/13_quarantine_correction.sql` exercises this end-to-end:
it lands the patient scenario 5 was missing, re-runs the pipeline, and
confirms `record_lineage_event` retains both scenario 5's original
quarantine decision and the new trusted one for the same `record_token`.

## 🔐 Governance & PHI

- [`governance/phi_classification.yml`](governance/phi_classification.yml) —
  column-level PHI/sensitivity classification and the minimum-necessary
  role → access matrix (`data_engineer`, `analyst`, `clinical_user`,
  `ai_agent`).
  **⚠️ Not enforced by the running stack.** This used to be mechanically
  enforced by Trino's file-based `rules.json`; DuckDB (this stack's current
  query engine — see "Architecture: DuckDB + DuckLake" above) has no
  equivalent per-role ACL layer. This file is documentation of the intended
  policy, not an enforced one, until that gap is closed — see its own KNOWN
  GAP note.
- Lineage/observability metadata (`record_token`, `source_event_id`,
  `pipeline_run_id`) is HMAC-keyed (not a plain hash — see
  `docs/lineage_token_rotation.md` for why that matters and how to set
  `RECORD_TOKEN_HMAC_KEY`) and carries no PHI values — see
  `warehouse/macros/lineage.sql` and the "lineage safety
  rules" in the PHI registry.

## 🧪 Reliability test suite

[`reliability-tests/`](reliability-tests/) exercises 13 scenarios — duplicate
events, out-of-order delivery, deletes, invalid references, impossible
clinical values, missing fields, unauthorized access, replay, outage
recovery, and a quarantine→trusted correction — against the questions this
platform needs to answer:

> Did we preserve the correct clinical state? Can we prove where it came
> from? Can we prove which quality checks it passed? Can we identify who
> accessed it? Can we replay the pipeline safely?

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs `dbt parse` and
4 of the 13 scenarios against a real Postgres service container on every PR.
[`.github/workflows/e2e-pipeline.yml`](.github/workflows/e2e-pipeline.yml)
runs the actual `docker compose` stack (Debezium → Postgres raw_cdc → dbt →
DuckDB/DuckLake) and asserts scenarios 01–07 and 13's outcomes — dedup,
ordering, deletes, referential integrity, clinical plausibility,
completeness, quarantine, and the quarantine→trusted history a correction
leaves behind — through the real reliability engine, not just at the
source. Scenario 08 (minimum-necessary access control) is not covered — see
"Architecture: DuckDB + DuckLake" above. It's nightly/on-demand, not a PR
gate, and its first real runs are still shakeout (see "What's actually
automated in CI" in `reliability-tests/README.md` for the honest version of
what's proven vs. what's aspirational).

---

## 🏗️ Quick Start

```bash
git clone https://github.com/yourusername/realtime-lakehouse-stack.git
cd realtime-lakehouse-stack/infra-setup
docker compose up -d
```

Once started:

- **Metabase** → http://localhost:3000
- **Warehouse (gold/deid/bronze/...)** → no UI; query it directly:
  `uv run python3 infra-setup/scripts/dq.py "SELECT * FROM gold.current_quality_summary"`
  (see "Architecture: DuckDB + DuckLake" above for why there's no server to
  point a UI at)

## 🤖 Data Transformation with dbt

The dbt project lives in `warehouse/` and is configured to connect via
`dbt-duckdb`, which attaches a self-hosted DuckLake catalog (Postgres-backed
— see "Architecture: DuckDB + DuckLake" above) plus a read-only view onto
the raw CDC landing tables.

```bash
uv sync                       # once, from the repo root
cd warehouse
../.venv/bin/dbt seed --profiles-dir .   # loads seeds/lab_reference_ranges.csv
../.venv/bin/dbt run  --profiles-dir .   # builds bronze → silver → quality → deid → gold
../.venv/bin/dbt test --profiles-dir .   # runs schema/data tests
```

*Pro-tip: `source .venv/bin/activate` once, then drop the `../.venv/bin/`
prefix.*

---

## 🧪 Coming Next

- Airflow orchestration example
- Expert Determination workflow for de-identified data
- Row/column-level audit logging of PHI access

## ⭐ Support the Project

If you find this stack helpful, please ⭐ **star the repository** and share it on LinkedIn!

---

© 2025–2026 — Built with ❤️ by Siddique Ahmad
