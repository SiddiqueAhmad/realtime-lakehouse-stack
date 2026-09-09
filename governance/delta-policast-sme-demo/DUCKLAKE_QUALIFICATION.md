# DuckLake Production Qualification Suite

Status: proposed executable qualification contract for Reference C.

This suite extends the already-passing governed-read reference. It does **not** change the existing 20 governance assertions. It qualifies the storage/catalog behavior around that reference and records limitations explicitly instead of weakening tests.

## Version lanes

| Lane | Purpose | Versions |
|---|---|---|
| `df53-baseline` | Current governed product reference | `datafusion-ducklake 0.3.0`, DataFusion 53.1, current pinned Policast |
| `df54-latest` | Newer DuckLake capability/correctness lane | latest pinned DF54-compatible DuckLake release (initial target `0.7.0`), DataFusion 54; **no governed parity claim until Policast moves from DF53** |

A result is one of:

- **PASS** — required behavior holds exactly.
- **SUPPORTED-BUT-FAILED** — upstream/library claims support but our integration fails; blocks qualification.
- **KNOWN-LIMITATION** — behavior is explicitly unsupported in this lane and fails safely/visibly. Silent wrong results are never a known limitation.
- **METRIC** — recorded evidence, not a flaky CI timing threshold.

## General invariants

Every correctness case must also prove:

1. no duplicate/lost business rows unless the case deliberately creates duplicates;
2. a fresh reader after the operation sees the same committed state as the writer;
3. failed writes never expose partial/torn state;
4. catalog metadata and object files agree for the current snapshot;
5. governance tests remain 20/20 after storage maintenance/schema cases where the governed schema is still valid;
6. scratch databases/catalogs/prefixes are unique and never mutate normal demo data.

---

## A. CDC semantics — simulated change application only

These tests qualify whether DuckLake can materialize a deterministic change stream. They do **not** claim Postgres WAL, Debezium offsets, connector restart, or exactly-once delivery.

### CDC-01 Initial state then insert

Setup: table contains `(1, A)`. Apply insert event `(2, B)`.

Assert: current state is exactly `{1:A, 2:B}`; fresh reader agrees; one logical row per key.

### CDC-02 Update existing key

Setup: `{1:A, 2:B}`. Apply update `2: B -> B2` using the lane's supported update/materialization mechanism.

Assert: exactly one key `2` exists and value is `B2`; old `B` is not visible in current state.

### CDC-03 Delete existing key

Setup: `{1:A, 2:B}`. Apply delete for key `2`.

Assert: current state contains only key `1`; fresh reader agrees.

### CDC-04 Duplicate replay / idempotent materialization

Apply the same logical update/delete batch twice using a deterministic event id/source sequence in the test harness.

Assert: final state is identical to applying it once; no duplicate current rows.

### CDC-05 Transaction batch visibility

Apply a logical transaction containing 25 row changes.

Assert: a reader can observe either the old committed state or the new committed state, never a partially applied subset.

### CDC-06 Out-of-order event characterization

Apply source sequence `102`, then stale `101` for the same key.

Assert: either the harness/storage contract rejects/ignores the stale event, or the lane is marked `KNOWN-LIMITATION`. Silently overwriting newer state with stale data is a failure for a future CDC implementation.

### CDC-07 Restart/replay boundary

Commit a change, recreate writer/provider/session, replay the final event, then read through a fresh provider.

Assert: state remains correct and catalog head is readable. This is storage replay qualification, not Debezium offset qualification.

---

## B. Concurrent production writes

### CONC-01 Concurrent appends to the same table

Run writer counts `2, 4, 8, 16`; each writer appends disjoint keys to one table.

Assert: all committed keys appear exactly once; no lost files/rows; snapshot ids are unique; fresh read matches expected count.

### CONC-02 Concurrent writes to different tables

Run 8 writers against 8 tables in one catalog.

Assert: every table is independently readable with its expected row; no cross-table metadata leakage.

### CONC-03 Concurrent data-bearing Replace conflict

Start two Replace sessions from the same base snapshot and commit concurrently.

Assert: no silent union/torn state. Expected contract is one winner plus one retryable conflict where the lane supports conflict detection.

### CONC-04 Append vs Replace race

Start Append and Replace from the same base.

Assert and record the exact final state. If stale Append is not conflict-checked, record `KNOWN-LIMITATION`; never claim serializable semantics.

### CONC-05 Reader snapshot during writes

Pin a reader to snapshot `N`, commit `N+1` and `N+2` concurrently.

Assert: pinned reader remains stable at `N`; a fresh reader sees the final committed head.

### CONC-06 Dropped/crashed write session

Begin a write, write batches to the staging session, then drop/abort before finish/commit.

Assert: no committed table/file becomes visible; orphan cleanup can safely identify any leftover physical object if one exists.

### CONC-07 Stress loop

Repeat same-table append and replace-conflict scenarios for at least 50 iterations at 2/4/8 writers.

Assert: zero silent corruption, duplicate/lost committed keys, or unreadable catalog heads.

---

## C. Multiwriter behavior

These differ from simple async concurrency: each writer gets an independent Postgres pool/provider/object-store client, approximating separate processes.

### MW-01 Independent writer instances same table

4 independent writers append disjoint key ranges.

Assert: union is exact and readable after all writer objects are destroyed/recreated.

### MW-02 Independent writers same base Replace

Two independent writers read the same head and attempt data-bearing Replace.

Assert: same conflict/serialization contract as CONC-03; no silent merge.

### MW-03 Monotonic catalog head

Collect committed snapshot ids from 100 writes across writers.

Assert: ids are unique; current head equals the maximum committed id for the catalog; every committed snapshot referenced by the catalog is structurally readable until expired.

### MW-04 Writer restart

Write, destroy process-level state, create new writer/pool, write again.

Assert: new writer continues from catalog state without local checkpoint/state files.

### MW-05 Lock timeout/retry characterization

Hold the relevant catalog lock long enough for another writer to contend.

Assert: contender returns a bounded, explicit retryable failure rather than hanging indefinitely or corrupting state.

### MW-06 Cross-catalog isolation

Two catalogs in the same Postgres metadata database write identically named `public.events` tables.

Assert: each catalog sees only its own table/files and physical file paths do not collide.

---

## D. Time travel / snapshot semantics

### TT-01 Explicit old snapshot read

Write snapshot `S1={1:A}`, then `S2={1:A,2:B}`. Open `DuckLakeCatalog::with_snapshot(..., S1)`.

Assert: S1 returns only `{1:A}`; current returns S2.

### TT-02 Snapshot pin remains stable

Open a provider/catalog pinned to S1, then commit S2/S3.

Assert: existing reader continues to return S1; newly opened current reader returns S3.

### TT-03 Historical schema read

Write schema v1, then add/drop a column in v2.

Assert: old snapshot exposes the old schema/data and current snapshot exposes current schema/data where the lane supports historical schema reconstruction.

### TT-04 Historical deleted/replaced rows

Replace/delete rows in a later snapshot.

Assert: old snapshot still returns prior state before expiration; current does not.

### TT-05 Expired snapshot is unavailable

Expire S1 using maintenance.

Assert: S1 is no longer advertised/readable and current head remains valid.

### TT-06 SQL time-travel syntax characterization

Attempt the user-facing SQL snapshot/time-travel syntax supported by the lane, if any.

Assert: exact result or an explicit `KNOWN-LIMITATION`; API-level snapshot support must not be mislabeled as SQL syntax support.

---

## E. Schema evolution

### SCHEMA-01 Add nullable column

v1: `(id, name)`. v2: add nullable `region`.

Assert: current schema includes `region`; new rows retain it; older files read as NULL/default according to lane contract.

### SCHEMA-02 Add required column without valid default

Attempt incompatible addition.

Assert: explicit rejection or documented behavior; no unreadable current snapshot.

### SCHEMA-03 Drop column

Drop `name` through supported schema operation/materialization path.

Assert: current schema omits it; historical snapshot still reads it if retained.

### SCHEMA-04 Rename column

Rename `name -> display_name` using the lane's supported mechanism.

Assert: current values survive rename; field identity/history are preserved according to the lane contract.

### SCHEMA-05 Widen numeric type

Promote supported widening such as Int32 -> Int64.

Assert: old files are readable through widened current schema with exact values.

### SCHEMA-06 Narrow/incompatible type change

Attempt Int64 -> Int32 or string -> integer.

Assert: fail explicitly and leave current table unchanged/readable.

### SCHEMA-07 Governance policy references removed/renamed column

After schema evolution, keep a policy referencing the old column.

Assert: governed query fails closed; it must never silently drop the policy filter/mask.

### SCHEMA-08 Concurrent schema/data race

Race schema evolution with an append based on the old schema.

Assert: one well-defined success/conflict outcome; no unreadable mixed schema.

---

## F. Maintenance / compaction

### MAINT-01 Snapshot expiration preserves current state

Create >=5 generations, expire all eligible old snapshots.

Assert: newest snapshot is never expired; current rowset/schema unchanged.

### MAINT-02 Cleanup dry-run is non-destructive

After expiration, call cleanup in dry-run mode.

Assert: it lists only reclaimable objects; object count/current reads remain unchanged.

### MAINT-03 Cleanup old files

Run actual cleanup.

Assert: scheduled superseded objects disappear; referenced live objects remain; current query still exact.

### MAINT-04 Orphan discovery/removal

Create an unreferenced `.parquet` under the catalog data path.

Assert: dry-run identifies it; actual cleanup removes it; referenced data is untouched.

### MAINT-05 Maintenance idempotency

Run expiration/cleanup/orphan cleanup twice.

Assert: second run is safe and produces no corruption; current state remains exact.

### MAINT-06 Small-file compaction

Create at least 32 small files for one table, compact with the lane's supported API.

Assert: rowset is byte/logically equivalent, file count materially decreases, and governance 20/20 remains valid for equivalent fixture/policy data.

### MAINT-07 Compaction with concurrent reader

Pin a reader before compaction, compact, then query pinned and fresh readers.

Assert: both snapshots remain internally consistent according to snapshot retention rules.

---

## G. Partition pruning / performance evidence

CI performance checks are structural/metric based, not wall-clock pass/fail thresholds.

### PERF-01 Unpartitioned selective filter baseline

Create >=32 files with disjoint key ranges and run a highly selective predicate.

Record: planning time, physical file count/listing count, bytes/row groups read where exposed, execution time.

### PERF-02 Partition-pruning structural check

Create a partitioned table with >=16 partitions in the DF54/latest lane and query one partition.

Assert: physical plan/file listing includes fewer files than the full table; ideally only the matching partition. DF53/v0.3 may be `KNOWN-LIMITATION`.

### PERF-03 Non-partition Parquet statistics pruning

Use disjoint min/max values per file/row group.

Assert/record whether DataFusion/DuckLake avoids irrelevant row groups/files.

### PERF-04 Governed vs raw provider pruning

Run the same selective query directly through DuckLake and through Policast + the conservative read boundary.

Record file/row-group counts for both. If governance intentionally prevents predicate pushdown, record that cost explicitly rather than claiming storage pruning.

### PERF-05 Scale metadata planning

Measure structural planning metrics for 10, 100, 1,000 data files without changing row count per file.

Record catalog queries/planning latency; no absolute CI latency gate initially.

### PERF-06 Cold/warm query evidence

Run each representative query once cold and five times warm.

Record median/p95 as evidence only. Performance regressions become gated only after a stable baseline exists.

---

## H. Newer DataFusion 54 / DuckLake lane

### DF54-01 Standalone compile

Build the pinned latest DF54 DuckLake adapter with Postgres metadata + MinIO and no bundled DuckDB.

Assert: compilation succeeds on AMD64 and ARM64 within the same documented CI memory envelope, or record the new resource requirement.

### DF54-02 Basic read/write parity

Write the healthcare + invoice fixtures and read exact rows through DataFusion 54.

Assert: exact fixture parity before testing advanced features.

### DF54-03 Native UPDATE / DELETE

Exercise native row-level DML supported by the newer adapter.

Assert: current-state correctness, snapshot atomicity, and fresh-reader parity.

### DF54-04 Maintenance + partition features

Run MAINT-01..07 and PERF-02/03 against the newer adapter.

Assert according to upstream-supported capabilities; a claimed-supported feature failure is `SUPPORTED-BUT-FAILED`.

### DF54-05 Governed integration compatibility gate

Attempt to construct the actual governed DuckLake provider against Policast.

Current expected state: **KNOWN-LIMITATION / blocked** because Policast's workspace pins DataFusion 53.1 while DuckLake 0.4+ uses DataFusion 54. Two different `TableProvider` trait versions cannot be passed across that boundary.

The test must make this incompatibility explicit; it must not hide it by running an ungoverned DF54 query and calling that governance parity.

### DF54-06 No accidental dual-DataFusion product binary

Dependency-tree/static check.

Assert: the production governed binary never ships both DF53 and DF54 and never adapts between incompatible `TableProvider` traits using unsafe/transmute tricks.

### DF54-07 Upgrade trigger

When Policast moves to a compatible DataFusion major, flip DF54-05 from characterization to a required run of the existing 20 governance cases, unchanged.

---

## CI layout

Recommended jobs:

```text
ducklake-qualification-df53
  AMD64 + ARM64
  existing governed-read 20/20
  CDC simulation
  concurrency + multiwriter
  snapshot/time-travel API
  schema evolution
  maintenance
  pruning/perf evidence

ducklake-qualification-df54
  AMD64 + ARM64
  standalone latest adapter
  native DML
  maintenance/partition capabilities
  explicit Policast compatibility gate
```

Stress cases can run on AMD64 on every PR and ARM64 nightly/explicit workflow if CI duration becomes excessive; correctness cases stay on both architectures.

## Merge rule

A DuckLake limitation does not block keeping Reference C, but it must be:

1. reproduced by a named test;
2. classified `KNOWN-LIMITATION` rather than silently skipped;
3. absent from product claims;
4. promoted to a required PASS when the selected dependency version claims support and we decide to rely on it.
