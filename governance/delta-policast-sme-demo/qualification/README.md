# Executable DuckLake qualification

`../test-ducklake-qualification.sh` builds and runs real behavioral tests, not the six manifest checks. Every one of the 54 manifest IDs has an executable case function. They coordinate independent Rust worker containers against real PostgreSQL and MinIO.

From `governance/delta-policast-sme-demo`:

```bash
bash test-ducklake-qualification.sh
# Reuse qualification images, not the governed-query image:
SKIP_BUILD=1 bash test-ducklake-qualification.sh
# One lane or selected cases:
LANE=df53 bash test-ducklake-qualification.sh
LANE=df54 SKIP_BUILD=1 bash test-ducklake-qualification.sh --case 'CONC-*' --case 'MW-*'
```

Python 3.10+ and Docker Compose are required. Host Rust is not required. Do not reset volumes. Each run creates/drops only a unique `ducklake_qualification_*` database and uses a unique `s3://lake/_ducklake_qualification/*` prefix. Synthetic objects are retained for inspection. Maintenance `CleanupCriteria::All` is used only in these isolated, quiescent scratch catalogs, not as a production retention recommendation.

## Lanes and boundaries

- DF53: DuckLake adapter 0.3.0, DataFusion 53.1.0 and the actual existing `app/src/query_runtime.rs`/Policast boundary for schema-policy and governed-I/O cases.
- DF54: DuckLake adapter 0.7.0, DataFusion 54.0.0 and SQLx 0.9, in a separate raw-storage worker. Not described as latest without a future version check. No claim of Policast governance on DF54.
- Both qualify the adapter's **library-specific PostgreSQL multicatalog layout**, not official DuckLake catalog-format interoperability with DuckDB.
- CDC is a single-materializer simulation with sequence numbers and tombstones persisted in DuckLake. DF54 also executes native UPDATE/DELETE. The test-only full-state Replace materializer is not a production CDC implementation: no WAL, Debezium, source offsets, cross-table transaction or exactly-once claims.
- Qualification images are separate from governed-query and governance-UI. Privileged write/cleanup operations are not installed into those product images.

## Outcomes

PASS means actual behavioral assertions held. FAILED covers wrong data/schema, failed assumptions, harness/process failures or unexpected infrastructure errors and makes CI exit nonzero. Cases continue independently to preserve the whole report. Failures are not automatically relabeled limitations.

KNOWN-LIMITATION records an explicit unsupported API/syntax response or the precisely checked stale-append characterization; it is not a pass. Silent wrong results and accepted expired snapshots fail. METRIC records measured queries whose row assertions held, without flaky time thresholds. BLOCKED identifies DF54 governance that cannot yet run. NOT_APPLICABLE identifies DF54-only cases in the DF53 report. Neither counts as PASS.

The report marks qualification incomplete when FAILED or BLOCKED is nonzero. The unchanged original 20-case governed suite remains independently enforced by `governed-delta.yml`; its green badge never overrides qualification failures.

## Evidence

`qualification-evidence/<lane>/<ID>.json` and `results.json` contain individual outcomes. Worker JSON-line journals retain synthetic rowsets, errors and barrier operations. Rust reports actual catalog snapshots/files/schema plus DataFusion physical plans, metrics and object-store read counts. Byte counters are response-range sizes including footers, not consumed network-byte/billing measurements.

Writes are prepared before concurrent finish calls; every future is joined and every worker failure propagates. Fault testing really SIGKILLs an independent writer container. Stress is 50 append iterations at 2/4/8 writers and 50 same-base Replace conflicts. Performance includes 10/100/1000 committed files plus fresh-process/repeated-query median/p95; no claim that OS or MinIO caches were flushed. These are functional/debug-profile builds without debug symbols, not optimized benchmarks.

Actions runs both lanes on native AMD64/ARM64 with 4 GiB/no-swap builders. Logs, exact Cargo.lock, dependency graphs and per-case evidence are uploaded on failures too. Source organization is under `tests/qualification/`; the manifest is a coverage contract, not the behavioral runner.
