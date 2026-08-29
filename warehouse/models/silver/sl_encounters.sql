{{ config(materialized='view', schema='silver', tags=['silver', 'phi']) }}

with base as (

    select * from {{ ref('br_encounters') }}
    where not is_deleted

)

{% set checks = {
    'missing_patient':         'patient_id is not null',
    'patient_not_found':       "patient_id in (select patient_id from " ~ ref('br_patients') ~ " where not is_deleted)",
    'missing_encounter_start': 'encounter_start is not null',
    'invalid_encounter_span':  'encounter_end is null or encounter_end >= encounter_start'
} %}

select
    b.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks,
    {{ lineage_columns('b.encounter_id', 'b.cdc_source_ts_ns') }}
from base b
