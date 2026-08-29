{{
  config(
    materialized='incremental',
    unique_key='provider_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze']
  )
}}

{% set source_columns %}
    provider_id,
    npi,
    first_name,
    last_name,
    specialty,
    facility_id
{% endset %}

{% set column_list %}
    provider_id, npi, first_name, last_name, specialty, facility_id
{% endset %}

{{ cdc_reliable_select('ehr', 'providers', 'provider_id', source_columns, column_list) }}
