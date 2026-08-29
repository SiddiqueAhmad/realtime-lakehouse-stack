{{
  config(
    materialized='incremental',
    unique_key='diagnosis_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    diagnosis_id,
    encounter_id,
    patient_id,
    icd10_code,
    description,
    diagnosed_at
{% endset %}

{% set column_list %}
    diagnosis_id, encounter_id, patient_id, icd10_code, description, diagnosed_at
{% endset %}

{{ cdc_reliable_select('ehr', 'diagnoses', 'diagnosis_id', source_columns, column_list) }}
