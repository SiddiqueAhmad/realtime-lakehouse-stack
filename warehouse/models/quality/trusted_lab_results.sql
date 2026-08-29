{{ config(materialized='view', schema='quality', tags=['quality', 'phi']) }}

select *
from {{ ref('sl_lab_results') }}
where quality_status = 'PASS'
