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
