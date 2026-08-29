{{
  config(
    materialized='incremental',
    unique_key='facility_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze']
  )
}}

{% set source_columns %}
    facility_id,
    name,
    npi,
    facility_type,
    city,
    state
{% endset %}

{% set column_list %}
    facility_id, name, npi, facility_type, city, state
{% endset %}

{{ cdc_reliable_select('ehr', 'facilities', 'facility_id', source_columns, column_list) }}
