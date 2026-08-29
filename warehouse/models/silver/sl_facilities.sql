{{ config(materialized='view', schema='silver', tags=['silver']) }}

with base as (

    select * from {{ ref('br_facilities') }}
    where not is_deleted

)

{% set checks = {
    'missing_name': 'name is not null',
    'missing_type': 'facility_type is not null'
} %}

select
    b.*,
    {{ dq_quality_status(checks) }} as quality_status,
    {{ dq_failed_checks(checks) }} as failed_checks,
    {{ lineage_columns('b.facility_id', 'b.cdc_source_ts_ns') }}
from base b
