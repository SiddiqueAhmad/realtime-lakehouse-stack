{{ config(materialized='view', schema='silver', tags=['silver']) }}

with base as (

    select * from {{ ref('br_providers') }}
    where not is_deleted

)

{% set checks = {
    'missing_npi':          'npi is not null',
    'missing_name':         'first_name is not null and last_name is not null',
    'facility_not_found':   "facility_id is null or facility_id in (select facility_id from " ~ ref('br_facilities') ~ " where not is_deleted)"
} %}

select
    b.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks
from base b
