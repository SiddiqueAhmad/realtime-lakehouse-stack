{{
  config(
    materialized='incremental',
    unique_key='lab_result_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    lab_result_id,
    patient_id,
    encounter_id,
    loinc_code,
    test_name,
    result_value,
    unit,
    abnormal_flag,
    result_at
{% endset %}

{% set column_list %}
    lab_result_id, patient_id, encounter_id, loinc_code, test_name,
    result_value, unit, abnormal_flag, result_at
{% endset %}

{{ cdc_reliable_select('ehr', 'debeziumcdc_dbz__ehr_lab_results', 'lab_result_id', source_columns, column_list) }}
