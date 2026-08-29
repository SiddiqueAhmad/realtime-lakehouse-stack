{#
  incremental_strategy='delete+insert', NOT 'merge': dbt-duckdb's adapter
  doesn't support it (its own valid_incremental_strategies() docstring
  says so directly: "DuckDB does not currently support MERGE statement") -
  confirmed the hard way, a real dbt run (e2e-pipeline.yml) failing with
  "The incremental strategy 'merge' is not valid for this adapter" once a
  model was actually re-run incrementally for the first time (its
  first-ever run always does a plain CREATE TABLE AS, so this wasn't
  caught by that run alone). delete+insert on unique_key is the supported
  equivalent here: cdc_reliable_select() (see macros/cdc_reliability.sql)
  already guarantees at most one row per natural key in each incremental
  batch (its own dedup CTE), so a delete-then-insert on that key is a real
  upsert, not an approximation.
#}
{{
  config(
    materialized='incremental',
    unique_key='observation_id',
    incremental_strategy='delete+insert',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    observation_id,
    patient_id,
    encounter_id,
    code,
    value,
    unit,
    observed_at
{% endset %}

{% set column_list %}
    observation_id, patient_id, encounter_id, code, value, unit, observed_at
{% endset %}

{{ cdc_reliable_select('ehr', 'observations', 'observation_id', source_columns, column_list) }}
