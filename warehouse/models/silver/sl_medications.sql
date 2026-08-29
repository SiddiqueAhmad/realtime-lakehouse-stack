{{ config(materialized='view', schema='silver', tags=['silver', 'phi']) }}

with base as (

    select * from {{ ref('br_medications') }}
    where not is_deleted

)

{% set checks = {
    'missing_patient':      'patient_id is not null',
    'patient_not_found':    "patient_id in (select patient_id from " ~ ref('br_patients') ~ " where not is_deleted)",
    'missing_name':         'name is not null',
    'invalid_date_range':   'end_date is null or end_date >= start_date'
} %}

select
    b.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks,
    {{ lineage_columns('b.medication_id', 'b.cdc_source_ts_ns') }}
from base b
