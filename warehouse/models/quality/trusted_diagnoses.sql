{{ config(materialized='view', schema='quality', tags=['quality', 'phi']) }}

select *
from {{ ref('sl_diagnoses') }}
where quality_status = 'PASS'
