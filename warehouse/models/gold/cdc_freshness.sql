{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- Freshness and CDC lag, per entity. Both are operational health signals,
-- not clinical data: no PHI-classified column is read or emitted here, only
-- timestamps, run ids, and row counts already carried on every bronze row
-- by the reliability engine (see macros/cdc_reliability.sql). Safe for the
-- same broad access tier as data_quality_summary.

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

per_dataset as (

    select
        dataset,
        max(cdc_source_ts_ns)               as latest_source_event_ts_ns,
        max(_loaded_at)                     as latest_loaded_at,
        max_by(pipeline_run_id, _loaded_at) as latest_pipeline_run_id,
        count(*)                            as bronze_row_count
    from unioned
    group by dataset

)

select
    dataset,
    from_unixtime(latest_source_event_ts_ns / 1e9) as latest_source_event_at,
    latest_loaded_at,
    latest_pipeline_run_id,
    bronze_row_count,
    -- CDC lag: seconds between the source committing a change and this
    -- pipeline run landing it in bronze. High/growing lag here is the
    -- earliest signal of a struggling Debezium/dbt schedule, well before
    -- data quality itself degrades.
    date_diff('second', from_unixtime(latest_source_event_ts_ns / 1e9), latest_loaded_at) as cdc_lag_seconds,
    -- Staleness: seconds between the most recent bronze load and "now"
    -- (when this observability model itself runs). Distinct from lag —
    -- a dataset can have low historical lag but still be stale right now
    -- if the pipeline has simply stopped running.
    date_diff('second', latest_loaded_at, {{ dbt.current_timestamp() }}) as staleness_seconds
from per_dataset
order by dataset
