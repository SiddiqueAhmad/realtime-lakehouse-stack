{{ config(materialized='view', schema='quality', tags=['quality', 'phi']) }}

-- Records that passed every data quality gate in sl_patients. This is the
-- "trusted" side of the PASS/FAIL split described in the platform's north
-- star architecture; downstream analytics/AI should read from here (or from
-- the de-identified models built on top of it), not directly off bronze.
select *
from {{ ref('sl_patients') }}
where quality_status = 'PASS'
