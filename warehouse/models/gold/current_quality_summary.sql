{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- CURRENT-STATE data quality per dataset: what fraction of the dataset's
-- present-day population is PASS, right now. Deliberately distinct from
-- data_quality_summary (a per-pipeline-run breakdown of PASS/FAIL counts):
-- that model groups by pipeline_run_id, and a metric that then SUMS
-- record_count across those groups is only correct if pipeline_run_id
-- partitions the current row population without overlap — true today
-- (bronze's incremental merge only stamps a new pipeline_run_id on rows it
-- actually re-merges; untouched rows keep an older one, so the current
-- snapshot's run-id groups don't double-count a row under two runs), but
-- that correctness is an implementation detail of the merge logic, not
-- something this metric's definition should have to depend on to be right.
--
-- This model sidesteps that entirely by computing directly off the live
-- silver views' current population — one row read, once, per dataset — so
-- "what does current_pass_rate_pct mean" never depends on reasoning about
-- how CDC merges attribute rows to runs.
--
-- Use data_quality_summary (still per-run) to see how a specific run's
-- batch looked; use this model to see how the dataset looks right now.

with unioned as (

    select 'patients'     as dataset, quality_status from {{ ref('sl_patients') }}
    union all
    select 'providers'    as dataset, quality_status from {{ ref('sl_providers') }}
    union all
    select 'facilities'   as dataset, quality_status from {{ ref('sl_facilities') }}
    union all
    select 'encounters'   as dataset, quality_status from {{ ref('sl_encounters') }}
    union all
    select 'diagnoses'    as dataset, quality_status from {{ ref('sl_diagnoses') }}
    union all
    select 'procedures'   as dataset, quality_status from {{ ref('sl_procedures') }}
    union all
    select 'medications'  as dataset, quality_status from {{ ref('sl_medications') }}
    union all
    select 'lab_results'  as dataset, quality_status from {{ ref('sl_lab_results') }}
    union all
    select 'observations' as dataset, quality_status from {{ ref('sl_observations') }}

)

select
    dataset,
    count(*)                                          as current_row_count,
    count(*) filter (where quality_status = 'PASS')    as current_passed_count,
    round(
        100.0 * count(*) filter (where quality_status = 'PASS') / nullif(count(*), 0),
        2
    ) as current_pass_rate_pct
from unioned
group by dataset
order by dataset
