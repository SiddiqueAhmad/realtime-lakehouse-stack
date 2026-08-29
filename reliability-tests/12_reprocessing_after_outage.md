# Scenario 12: Reprocessing after outage

**Question:** can we replay the pipeline safely, even after a longer outage
that forces reprocessing from an earlier point?

This is scenario 11 taken further: instead of a brief kill/restart, simulate
Debezium having to reprocess a range of already-seen events (e.g. because its
offset storage was rolled back, or a batch is manually replayed for audit
purposes).

## Setup

1. Run a normal batch and let it fully process (per scenario 10, step 1–2).
2. Re-run the same raw INSERT statements used in scenario 03
   (`03_out_of_order_replay.sql`) directly against the Iceberg CDC table
   — this simulates Debezium redelivering events it already sent once.
3. Run `dbt run --select br_lab_results sl_lab_results --profiles-dir .`.

## Expected

- Reprocessing already-applied events converges to the same state as before
  (per-key ordering guard in `cdc_reliable_select`), not a duplicate or a
  regression to a stale value — this is exactly what scenario 03 verifies,
  and the point here is that it holds even when the "redelivery" spans a
  full outage/recovery cycle rather than a single out-of-order insert.
- `gold.data_quality_summary` row counts for `lab_results` do not inflate
  from the redelivery — reprocessing must not manufacture new rows for
  events that were already merged.
