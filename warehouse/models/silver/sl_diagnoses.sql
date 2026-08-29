{{ config(materialized='view', schema='silver', tags=['silver', 'phi']) }}

with base as (

    select * from {{ ref('br_diagnoses') }}
    where not is_deleted

)

{% set checks = {
    'missing_patient':     'patient_id is not null',
    'patient_not_found':   "patient_id in (select patient_id from " ~ ref('br_patients') ~ " where not is_deleted)",
    'encounter_not_found': "encounter_id in (select encounter_id from " ~ ref('br_encounters') ~ " where not is_deleted)",
    'missing_icd10':       'icd10_code is not null',
    'future_diagnosis':    'diagnosed_at <= current_timestamp'
} %}

select
    b.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks
from base b
