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
    tags=['gold']
  )
}}


-- Aggregate-only encounter metrics. No PHI-classified column is selected —
-- patient_id is used only inside count(distinct ...) to size the cohort,
-- never emitted as a value — so this table is safe for the broad
-- "analyst" access tier (see governance/phi_classification.yml).

select
    cast(encounter_start as date) as encounter_date,
    encounter_type,
    count(distinct encounter_id) as encounter_count,
    count(distinct patient_id)   as unique_patients
from {{ ref('trusted_encounters') }}
group by cast(encounter_start as date), encounter_type
order by encounter_date, encounter_type
