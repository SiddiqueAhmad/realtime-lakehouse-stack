{{ config(materialized='view', schema='silver', tags=['silver', 'phi']) }}

with base as (

    select * from {{ ref('br_lab_results') }}
    where not is_deleted

),

with_ranges as (
    -- Clinical plausibility bounds are config-driven (seeds/lab_reference_ranges.csv),
    -- not hardcoded, so they can be reviewed/extended without touching model logic.
    select
        b.*,
        r.min_plausible_value,
        r.max_plausible_value
    from base b
    left join {{ ref('lab_reference_ranges') }} r
        on b.loinc_code = r.loinc_code
)

{% set checks = {
    'missing_patient':          'patient_id is not null',
    'patient_not_found':        "patient_id in (select patient_id from " ~ ref('br_patients') ~ " where not is_deleted)",
    'missing_result_value':     'result_value is not null',
    'result_out_of_range':      '(min_plausible_value is null or result_value >= min_plausible_value)
        and (max_plausible_value is null or result_value <= max_plausible_value)',
    'future_result':            'result_at <= current_timestamp'
} %}

select
    w.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks
from with_ranges w
