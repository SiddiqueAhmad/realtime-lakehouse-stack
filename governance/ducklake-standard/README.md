# Standard PostgreSQL DuckLake + Policast / DataFusion 54.1

An isolated, executable qualification reference. The original Delta, Iceberg and
experimental DuckLake references under `../delta-policast-sme-demo` are unchanged.

## Dependency and storage boundary

- DataFusion 54.1.0; one Arrow dependency family.
- `datafusion-ducklake` 0.7.0 source pinned at
  `ad1b8c433179192e09bf66e8c84c46d61ba9306e`.
- `PostgresSingleCatalogMetadataWriter` and `PostgresMetadataProvider`.
  Every catalog has its own PostgreSQL schema/search_path inside a scratch database;
  no library-specific multicatalog tables or `catalog_id` columns are created.
- Pinned Policast `c6891d553fa1105546668c75b9a0d175bc54f70d` with a narrow LOCAL
  DF54 compatibility port of the generic TableProvider. Parser, filter and masking
  logic are unchanged. Optional upstream Delta/UC adapters are not compiled here.
- MinIO for files. No DuckDB runtime, broker, CDC connector or catalog service.
- Committed `Cargo.lock` with SHA-256
  `4cfd29d6f7b732fc4d2666dd0fcbe1333f224d9a675b0db1a50e59682e873a38`.
  Both control and corrected builds require `--locked`.

## Corrections under test

`prepare.py` stages pinned sources using checked edits and emits an auditable
`upstream-changes.patch`, including the Policast manifest adjustment.

1. Explicit snapshot IDs are validated against the provider's snapshot listing.
   Missing/expired IDs fail rather than produce plausible successful results.
2. Prepared writes check for newer table DDL inside the same commit transaction
   holding the snapshot-counter lock. A stale schema returns `Conflict`; the
   transaction rolls back. Append cannot retire omitted live columns even when
   submitted sequentially. Reopen under the current schema before retrying.
3. A separate defect exposed by full qualification is corrected: the standard
   writer's `SELECT 1` conflict probe returned PostgreSQL INT4 but decoded `i64`.
   Selecting `1::BIGINT` preserves the intended retryable conflict error.

These are local patches, not claims of upstream fixes or a released DF54 Policast.
The production query boundary still prevents unsafe projection/filter/limit pushdown.

## Run

From this directory, with Docker Compose and Python 3.10+:

```bash
bash test-standard.sh
python3 test_guards.py
```

Once the CURRENT qualification image exists:

```bash
SKIP_BUILD=1 bash test-standard.sh --case TT-05 --case SCHEMA-08 --case 'DF54-*'
```

The first command builds with Rust tests, starts this reference's own PostgreSQL
and MinIO stack, and executes the 54-case profile. `DF54-07` imports and runs the
original 20-case governance file unchanged, substituting only its Compose deployment.
Do not substitute the old `governed-query` image. No host Rust is required.

Results: `evidence/df54/results.json`, per-case JSON, worker journals and
`governance-20.log`. Additional guards: `guard-evidence/df54/guards.json`.
The stack publishes no host ports. Scratch databases and prefixes isolate normal
demo data. Stop it with `docker compose down`; no volume reset is needed.

## CI proof and honest limitations

The dedicated workflow first builds `FIXES=0` and requires the two exact regression
failures (`TT-05`, `SCHEMA-08`). Infrastructure failures cannot satisfy this control.
It then builds `FIXES=1` with the SAME lock, executes all 54 case handlers and the
unchanged 20 governance cases, then verifies invalid IDs, valid empty snapshots,
physical catalog layout, conflict typing, atomic rollback and fresh-schema retry.
Both AMD64 and ARM64 run natively with 4 GiB/no-swap builders.

A backend change does not inherit passes from another backend. Upstream 0.7.0's
standard PostgreSQL writer lacks native UPDATE/DELETE/upsert, type promotion,
compaction and cleanup/expiry/orphan APIs implemented on other backends. Attempted
unsupported operations are classified only after checking committed metadata and
rows are unchanged. Limitations and measurements are not passing cases.

`TT-05` uses a clearly labelled LOGICAL-EXPIRY TEST FIXTURE: it removes an old
snapshot listing entry while preserving the head and physical files. This proves
unavailable-snapshot rejection, NOT native garbage collection, safe retention under
concurrent physical deletion, or maintenance support. `MAINT-01` is a limitation.

CDC remains single-materializer simulation, not WAL/Debezium/transport recovery.
Standard catalog shape is tested, but cross-engine DuckDB write interoperability,
full DuckLake-spec conformance, and migration from the experimental catalog are NOT
claimed. Start with fresh catalogs, not an in-place switch of the older demo.

Before the conflict-decoding correction, both target regressions and the original
20 governance cases passed, but three broader cases failed on that decoding error.
The corrected commit must complete its own CI run; this README does not predeclare
its outcome. The PR records inspected, commit-specific final evidence.
