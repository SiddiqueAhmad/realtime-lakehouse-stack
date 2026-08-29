# Scenario 10: Pipeline replay

**Question:** can we replay the pipeline safely?

## Setup

1. Run a normal batch: make a handful of writes to `ehr` (e.g. scenarios 1–7),
   let Debezium stream them, then run `dbt run --profiles-dir .` from
   `warehouse/`.
2. Record the resulting row counts and a few sample values from
   `bronze.br_patients`, `silver.sl_patients`, `quality.trusted_patients`, and
   `gold.data_quality_summary` (excluding `pipeline_run_id`, which is
   expected to change every run).

## Replay

3. Re-run `dbt run --profiles-dir .` again, with **no new source writes**.

## Expected

- Every `bronze.*` and `silver.*`/`quality.*` model is unchanged except for
  `pipeline_run_id` and `_loaded_at`/lineage columns that are meant to change
  per run. Row counts, `quality_status`, and clinical values must be
  identical to step 2 — a plain re-run must be a no-op on the data.
- This works because `cdc_reliable_select`'s merge is keyed by natural key,
  and because Iceberg's REST catalog + `incremental_strategy='merge'` make
  the operation itself idempotent: re-merging the same rows converges rather
  than duplicating or drifting.
