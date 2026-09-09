# Standard PostgreSQL DuckLake + Policast / DataFusion 54 qualification

Status: implementation under CI qualification; not a production-ready declaration.

This isolated reference is stacked on PR #18. It does not upgrade the original
Delta/Iceberg/DuckLake binary or mutate their datasets.

## Stack and provenance

- datafusion-ducklake 0.7.0, upstream commit ad1b8c433179192e09bf66e8c84c46d61ba9306e
- DataFusion 54.1.0, one coherent Arrow release family
- Policast c6891d553fa1105546668c75b9a0d175bc54f70d with a **local compatibility port**
- PostgresSingleCatalogMetadataWriter + PostgresMetadataProvider
- PostgreSQL and MinIO; no DuckDB runtime, CDC connector, Spark, Kafka, Flink or REST catalog

Each logical catalog uses a separate PostgreSQL schema/search_path inside a
unique scratch database. There are no library-specific catalog_id/map tables.
This tests the standard catalog layout; it does NOT prove bidirectional DuckDB
writer compatibility or an in-place upgrade of the experimental multi-catalog.

## Changes being qualified

prepare.py stages copies of pinned source inputs. Checked substitutions abort
on input drift; no original reference source is modified.

1. with_snapshot validates that the requested snapshot exists.
2. The standard writer checks concurrent schema changes under its transactional
   snapshot-counter lock before reconciling columns. Append cannot remove a live
   column even when given a stale schema sequentially.
3. The generic Policast TableProvider implementation is ported to DF54 by removing
   the obsolete as_any trait methods and selecting DF54 dependencies. Policy
   parsing, CEL translation, filtering and masking logic are retained. Optional
   Policast Delta/UC adapters are excluded from this isolated port.
4. The same control-plane modules and conservative ReadBoundary are compiled
   against this stack; the unchanged original 20-case test file runs against it.

The generated upstream patch and exact build dependency graph are retained in
CI artifacts. FIXES=0 builds the same standard stack without the two storage
fixes. CI requires both targeted controls to fail with the expected behavioral
symptoms before running the corrected stack.

## Important capability boundaries

The standard writer in this pinned version is narrower than the experimental
multi-catalog writer. Native update/delete, numeric promotion and compaction can
return unsupported backend operations. Standard PostgreSQL native snapshot
maintenance/GC is not implemented upstream in this version.

The expiry regression uses a clearly labelled privileged **logical-expiry test
fixture**: it removes old snapshot listing entries, preserves the head, and never
reclaims files or column/file visibility metadata. This proves invalid-snapshot
handling, not native maintenance. MAINT-01 is explicitly a limitation, not a pass.

Unsupported operation reports require a matching unsupported error and unchanged
catalog/row data. Wrong rows, crashes, missing objects and unexpected infrastructure
errors are failures. All 54 case IDs remain accounted for; the former blocked DF54
governance cases now invoke actual Policast and the original governance suite.
CDC remains single-materializer simulation, not WAL or connector qualification.

## Local execution

From the repository root:

```bash
cd governance/ducklake-standard
bash test-standard.sh
# Reuse this reference's image, not the original governed-query image:
SKIP_BUILD=1 bash test-standard.sh --case TT-05 --case SCHEMA-08 --case 'DF54-*'
python3 test_guards.py
```

Docker Compose and Python 3.10+ are required. No host Rust installation is needed.
This Compose project publishes no ports and uses its own volumes, so the original
demo may remain running. Do not use down -v: no volume reset is required.

Results are in evidence/df54/results.json, per-case files and worker journals.
The 20-case governed log is evidence/df54/governance-20.log.

Exact lockfile capture/commit is required before declaring reproducible release
qualification. Until CI has completed, do not infer success from these files.
