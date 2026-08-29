{{
  config(
    materialized='incremental',
    unique_key='patient_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    id as patient_id,
    medical_record_number,
    first_name,
    last_name,
    date_of_birth,
    gender,
    email,
    phone,
    address_line1,
    city,
    state,
    postal_code,
    is_deceased
{% endset %}

{% set column_list %}
    patient_id, medical_record_number, first_name, last_name, date_of_birth,
    gender, email, phone, address_line1, city, state, postal_code, is_deceased
{% endset %}

{{ cdc_reliable_select('ehr', 'debeziumcdc_dbz__ehr_patients', 'patient_id', source_columns, column_list) }}
