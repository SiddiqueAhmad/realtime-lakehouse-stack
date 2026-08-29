{{
  config(
    materialized='incremental',
    unique_key='procedure_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    schema='bronze',
    tags=['bronze', 'phi']
  )
}}

{% set source_columns %}
    procedure_id,
    encounter_id,
    patient_id,
    cpt_code,
    description,
    performed_at
{% endset %}

{% set column_list %}
    procedure_id, encounter_id, patient_id, cpt_code, description, performed_at
{% endset %}

{{ cdc_reliable_select('ehr', 'procedures', 'procedure_id', source_columns, column_list) }}
