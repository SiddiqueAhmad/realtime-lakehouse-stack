{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- Operational lineage / incident-investigation trace: for every record in
-- the 4 entities with a full quality-gate + quarantine split (patients,
-- encounters, diagnoses, lab_results — see models/quality/), one row
-- answering "why is this record in the state it's in, right now":
--
--   Patient record
--        |
--   CDC event (source_event_id: which transaction/LSN produced this
--        |     version of the row — see macros/lineage.sql)
--        v
--   Processing (pipeline_run_id: which dbt run merged it into bronze)
--        |
--        v
--   Quality decision (quality_status / failed_checks)
--        |
--    +---+---+
--    v       v
-- trusted quarantine        (or neither, if the record was deleted before
--                             ever reaching a quality decision)
--
-- This is CURRENT-STATE lineage: one row per record, its most recent
-- quality decision only. A record that failed, was quarantined, got
-- corrected at the source, and later passed shows only the latter here —
-- the earlier quarantine episode isn't retained by this model. A
-- historical/incident-timeline model (one row per quality decision, not
-- per record) is future work, not this one.
--
-- Deliberately PHI-free: only record_token (not the natural key) and
-- operational/lineage metadata, never a PHI/QUASI_PHI value column. That's
-- what makes this safe for the same broad access tier as the other gold
-- observability models (see governance/phi_classification.yml) — an
-- analyst or an AI agent can investigate "why is this record currently
-- quarantined" without ever touching a clinical value. Resolving
-- record_token back to the underlying row in bronze/silver is a separate,
-- governed lookup gated on its own access tier, not something the token
-- itself grants — a clinical_user/data_engineer still has to go through
-- that lookup, not just read the token, to reach the PHI.

with patients_lineage as (

    select
        'patients'    as dataset,
        b.record_token,
        b.source_event_id,
        b.pipeline_run_id,
        b.cdc_operation,
        b.is_deleted,
        b.cdc_source_lsn,
        b.cdc_transaction_id,
        b.cdc_transaction_total_order,
        s.quality_status,
        s.failed_checks,
        (t.record_token is not null) as is_trusted,
        (q.record_token is not null) as is_quarantined
    from {{ ref('br_patients') }} b
    left join {{ ref('sl_patients') }} s         on s.record_token = b.record_token
    left join {{ ref('trusted_patients') }} t    on t.record_token = b.record_token
    left join {{ ref('quarantine_patients') }} q on q.record_token = b.record_token

),

encounters_lineage as (

    select
        'encounters'  as dataset,
        b.record_token,
        b.source_event_id,
        b.pipeline_run_id,
        b.cdc_operation,
        b.is_deleted,
        b.cdc_source_lsn,
        b.cdc_transaction_id,
        b.cdc_transaction_total_order,
        s.quality_status,
        s.failed_checks,
        (t.record_token is not null) as is_trusted,
        (q.record_token is not null) as is_quarantined
    from {{ ref('br_encounters') }} b
    left join {{ ref('sl_encounters') }} s         on s.record_token = b.record_token
    left join {{ ref('trusted_encounters') }} t    on t.record_token = b.record_token
    left join {{ ref('quarantine_encounters') }} q on q.record_token = b.record_token

),

diagnoses_lineage as (

    select
        'diagnoses'   as dataset,
        b.record_token,
        b.source_event_id,
        b.pipeline_run_id,
        b.cdc_operation,
        b.is_deleted,
        b.cdc_source_lsn,
        b.cdc_transaction_id,
        b.cdc_transaction_total_order,
        s.quality_status,
        s.failed_checks,
        (t.record_token is not null) as is_trusted,
        (q.record_token is not null) as is_quarantined
    from {{ ref('br_diagnoses') }} b
    left join {{ ref('sl_diagnoses') }} s         on s.record_token = b.record_token
    left join {{ ref('trusted_diagnoses') }} t    on t.record_token = b.record_token
    left join {{ ref('quarantine_diagnoses') }} q on q.record_token = b.record_token

),

lab_results_lineage as (

    select
        'lab_results' as dataset,
        b.record_token,
        b.source_event_id,
        b.pipeline_run_id,
        b.cdc_operation,
        b.is_deleted,
        b.cdc_source_lsn,
        b.cdc_transaction_id,
        b.cdc_transaction_total_order,
        s.quality_status,
        s.failed_checks,
        (t.record_token is not null) as is_trusted,
        (q.record_token is not null) as is_quarantined
    from {{ ref('br_lab_results') }} b
    left join {{ ref('sl_lab_results') }} s         on s.record_token = b.record_token
    left join {{ ref('trusted_lab_results') }} t    on t.record_token = b.record_token
    left join {{ ref('quarantine_lab_results') }} q on q.record_token = b.record_token

)

select * from patients_lineage
union all
select * from encounters_lineage
union all
select * from diagnoses_lineage
union all
select * from lab_results_lineage
