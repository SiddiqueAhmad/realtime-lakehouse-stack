{{ config(materialized='view', schema='quality', tags=['quality', 'phi']) }}

select *
from {{ ref('sl_encounters') }}
where quality_status = 'FAIL'
