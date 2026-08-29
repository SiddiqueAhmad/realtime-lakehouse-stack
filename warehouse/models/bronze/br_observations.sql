{{
  config(
    materialized='incremental',
    unique_key='observation_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    id as observation_id,
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

{{ cdc_reliable_select('ehr', 'debeziumcdc_dbz__ehr_observations', 'observation_id', source_columns, column_list) }}
