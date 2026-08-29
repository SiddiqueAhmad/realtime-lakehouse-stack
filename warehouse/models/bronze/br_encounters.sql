{{
  config(
    materialized='incremental',
    unique_key='encounter_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    id as encounter_id,
    patient_id,
    provider_id,
    facility_id,
    encounter_type,
    status,
    encounter_start,
    encounter_end
{% endset %}

{% set column_list %}
    encounter_id, patient_id, provider_id, facility_id, encounter_type,
    status, encounter_start, encounter_end
{% endset %}

{{ cdc_reliable_select('ehr', 'debeziumcdc_dbz__ehr_encounters', 'encounter_id', source_columns, column_list) }}
