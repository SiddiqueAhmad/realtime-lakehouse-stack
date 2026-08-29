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
