{{ config(materialized='view', schema='quality', tags=['quality', 'phi']) }}

-- Records that failed one or more data quality gates in sl_patients.
-- Quarantined, not dropped: failed_checks names the reason(s) so an
-- operator can triage without re-deriving the logic, and the row can be
-- reprocessed once source data is corrected (see reliability-tests/).
select *
from {{ ref('sl_patients') }}
where quality_status = 'FAIL'
