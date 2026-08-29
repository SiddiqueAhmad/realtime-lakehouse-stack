-- Singular test: a record must never be both is_trusted AND is_quarantined
-- at the same time, in either record_lineage (current-state) or
-- record_lineage_event (history) - trusted_* and quarantine_* are a
-- partition of quality_status (PASS / FAIL respectively, see
-- macros/data_quality.sql), so this already holds by construction today;
-- this test makes that state-machine invariant an explicit, standing check
-- rather than an assumption a future change to either quality model could
-- silently break. Passes when this returns zero rows.

select 'record_lineage' as source_model, record_token, dataset, quality_status
from {{ ref('record_lineage') }}
where is_trusted and is_quarantined

union all

select 'record_lineage_event' as source_model, record_token, dataset, quality_status
from {{ ref('record_lineage_event') }}
where is_trusted and is_quarantined
