{{
  config(
    materialized='incremental',
    unique_key='medication_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    medication_id,
    patient_id,
    encounter_id,
    ndc_code,
    name,
    dosage,
    start_date,
    end_date
{% endset %}

{% set column_list %}
    medication_id, patient_id, encounter_id, ndc_code, name, dosage,
    start_date, end_date
{% endset %}

{{ cdc_reliable_select('ehr', 'debeziumcdc_dbz__ehr_medications', 'medication_id', source_columns, column_list) }}
