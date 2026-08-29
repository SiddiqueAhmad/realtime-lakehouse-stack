{{ config(materialized='view', schema='silver', tags=['silver', 'phi']) }}

with base as (

    select * from {{ ref('br_patients') }}
    where not is_deleted

)

{% set checks = {
    'missing_mrn':   'medical_record_number is not null',
    'missing_name':  'first_name is not null and last_name is not null',
    'invalid_dob':   'date_of_birth is not null and date_of_birth <= current_date',
    'invalid_email': "email is null or regexp_like(email, '^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$')"
} %}

select
    b.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks,
    {{ lineage_columns('b.patient_id', 'b.cdc_source_ts_ns') }}
from base b
