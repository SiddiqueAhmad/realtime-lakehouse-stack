{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- Observability rollup: how many records passed/failed data quality gates,
-- per dataset, per pipeline run. Deliberately carries no PHI-classified
-- columns — only dataset name, run id, status, and counts — so it can be
-- used freely in dashboards, alerts, and by an AI agent operating under the
-- "data_engineer" / "analyst" access tier (see governance/phi_classification.yml).

with unioned as (

    select 'patients'     as dataset, quality_status, pipeline_run_id from {{ ref('sl_patients') }}
    union all
    select 'providers'    as dataset, quality_status, pipeline_run_id from {{ ref('sl_providers') }}
    union all
    select 'facilities'   as dataset, quality_status, pipeline_run_id from {{ ref('sl_facilities') }}
    union all
    select 'encounters'   as dataset, quality_status, pipeline_run_id from {{ ref('sl_encounters') }}
    union all
    select 'diagnoses'    as dataset, quality_status, pipeline_run_id from {{ ref('sl_diagnoses') }}
    union all
    select 'procedures'   as dataset, quality_status, pipeline_run_id from {{ ref('sl_procedures') }}
    union all
    select 'medications'  as dataset, quality_status, pipeline_run_id from {{ ref('sl_medications') }}
    union all
    select 'lab_results'  as dataset, quality_status, pipeline_run_id from {{ ref('sl_lab_results') }}
    union all
    select 'observations' as dataset, quality_status, pipeline_run_id from {{ ref('sl_observations') }}

)

select
    dataset,
    pipeline_run_id,
    quality_status,
    count(*) as record_count
from unioned
group by dataset, pipeline_run_id, quality_status
order by dataset, quality_status
