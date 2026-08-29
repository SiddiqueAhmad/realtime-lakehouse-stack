{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- Overall pass rate per dataset, rolled up across every pipeline run
-- recorded in data_quality_summary. Complements the per-run breakdown
-- there with the single number a dashboard/alert usually wants first.

select
    dataset,
    sum(record_count) as total_records,
    sum(case when quality_status = 'PASS' then record_count else 0 end) as passed_records,
    round(
        100.0 * sum(case when quality_status = 'PASS' then record_count else 0 end)
        / nullif(sum(record_count), 0),
        2
    ) as pass_rate_pct
from {{ ref('data_quality_summary') }}
group by dataset
order by dataset
