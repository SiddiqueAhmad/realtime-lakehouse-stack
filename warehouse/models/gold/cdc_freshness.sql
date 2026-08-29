{#
  materialized='incremental' + incremental_strategy='append' + a pre_hook
  DELETE, NOT materialized='table': DuckLake has a confirmed, currently-
  open upstream bug (duckdb/ducklake#509) where a table (or view)
  materialization's second build - dbt's standard create-a-`__dbt_tmp`-
  relation-then-RENAME-it-over-the-target pattern, which BOTH the table
  and view materializations use unconditionally - fails with "Cannot
  rename table X__dbt_tmp to X, since X__dbt_tmp already exists" once X
  has been built once before. Hit this exact error, on this exact model,
  on a real run (e2e-pipeline.yml 33258763463) the first time any gold
  model was ever rebuilt a second time in this migration.

  dbt-duckdb's incremental materialization only does that same rename
  dance when doing a genuine `--full-refresh` (or the target doesn't
  exist yet); on an ordinary incremental run it instead runs the
  configured strategy's SQL directly against the existing table - no
  rename, so the ducklake bug never triggers. This model has no natural
  partition to append incrementally (it's a full recompute of current
  state every run), so the pre_hook DELETEs everything first - only when
  is_incremental() (never on the very first build, when the table doesn't
  exist yet) - and 'append' then does a plain, unconditional INSERT of
  the freshly computed rows. Net effect is the same full-refresh-every-run
  semantics materialized='table' had, without ever renaming a relation.
  Revisit once ducklake#509 is fixed upstream.
#}
{{
  config(
    materialized='incremental',
    incremental_strategy='append',
    pre_hook="{% if is_incremental() %}delete from {{ this }}{% endif %}",
    schema='gold',
    tags=['gold', 'observability']
  )
}}


-- Freshness and CDC lag, per entity. Both are operational health signals,
-- not clinical data: no PHI-classified column is read or emitted here, only
-- timestamps, run ids, and row counts already carried on every bronze row
-- by the reliability engine (see macros/cdc_reliability.sql). Safe for the
-- same broad access tier as data_quality_summary.
--
-- Definition, precisely: for each dataset, find the ONE bronze row with the
-- latest _loaded_at (the most recently processed event) and report ITS OWN
-- cdc_source_ts_ns -> _loaded_at gap as cdc_lag_seconds. Independently
-- taking max(cdc_source_ts_ns) and max(_loaded_at) and subtracting them is
-- wrong: those maxima don't have to come from the same row, so the "lag"
-- would be the gap between two unrelated events rather than the actual
-- source-to-load latency of anything real. This answers "how long did the
-- most recently processed event take to land", not "what's the oldest gap
-- we've ever seen" or "what's the newest event we're aware of at the
-- source" — those are different signals this model does not attempt to
-- report.

with unioned as (

    select 'patients'     as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_patients') }}
    union all
    select 'providers'    as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_providers') }}
    union all
    select 'facilities'   as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_facilities') }}
    union all
    select 'encounters'   as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_encounters') }}
    union all
    select 'diagnoses'    as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_diagnoses') }}
    union all
    select 'procedures'   as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_procedures') }}
    union all
    select 'medications'  as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_medications') }}
    union all
    select 'lab_results'  as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_lab_results') }}
    union all
    select 'observations' as dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id from {{ ref('br_observations') }}

),

ranked as (

    select
        *,
        row_number() over (partition by dataset order by _loaded_at desc) as _rn
    from unioned

),

latest_processed as (

    select dataset, cdc_source_ts_ns, _loaded_at, pipeline_run_id
    from ranked
    where _rn = 1

),

row_counts as (

    select dataset, count(*) as bronze_row_count
    from unioned
    group by dataset

)

select
    lp.dataset,
    to_timestamp(lp.cdc_source_ts_ns / 1e9) as latest_processed_source_event_at,
    lp._loaded_at                            as latest_processed_loaded_at,
    lp.pipeline_run_id                       as latest_processed_pipeline_run_id,
    rc.bronze_row_count,
    -- Source-to-load latency of the SAME event, not two independently
    -- chosen timestamps.
    date_diff('second', to_timestamp(lp.cdc_source_ts_ns / 1e9), lp._loaded_at) as cdc_lag_seconds,
    -- How long ago that same event was landed, relative to now (when this
    -- observability model itself runs). Distinct from lag — a dataset can
    -- have low historical lag but still be stale right now if the pipeline
    -- has simply stopped running.
    date_diff('second', lp._loaded_at, {{ dbt.current_timestamp() }}) as staleness_seconds
from latest_processed lp
join row_counts rc on rc.dataset = lp.dataset
order by lp.dataset
