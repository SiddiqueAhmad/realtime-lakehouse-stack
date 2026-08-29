{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- Reliability-relevant CDC volume, per entity: not just raw-event-count vs.
-- current-row-count (which conflates "many legitimate updates to few keys"
-- with "many duplicate deliveries" — both produce a high ratio, and they
-- mean completely different things operationally), but an explicit
-- duplicate_event_count computed from what "duplicate" actually means for
-- this pipeline: two or more raw log rows sharing the same (natural key,
-- LSN) — i.e. the literal same CDC event, redelivered (see
-- reliability-tests/01_duplicate_event.sql). A row with a different LSN for
-- the same key is a distinct, legitimate change event, not a duplicate,
-- however many of those a key has accumulated.
--
-- Counts only — no PHI-classified column is read or emitted.

with raw_unioned as (

    select 'patients'     as dataset, patient_id     as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_patients') }}
    union all
    select 'providers'    as dataset, provider_id    as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_providers') }}
    union all
    select 'facilities'   as dataset, facility_id    as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_facilities') }}
    union all
    select 'encounters'   as dataset, encounter_id   as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_encounters') }}
    union all
    select 'diagnoses'    as dataset, diagnosis_id   as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_diagnoses') }}
    union all
    select 'procedures'   as dataset, procedure_id   as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_procedures') }}
    union all
    select 'medications'  as dataset, medication_id  as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_medications') }}
    union all
    select 'lab_results'  as dataset, lab_result_id  as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_lab_results') }}
    union all
    select 'observations' as dataset, observation_id as natural_key, __source_lsn as lsn, __op as cdc_operation from {{ source('ehr', 'debeziumcdc_dbz__ehr_observations') }}

),

-- One row per distinct (dataset, natural_key, lsn) — i.e. per genuinely
-- distinct CDC event, regardless of how many times it was delivered.
raw_grouped as (

    select
        dataset,
        natural_key,
        lsn,
        count(*)                as delivery_count,
        arbitrary(cdc_operation) as cdc_operation
    from raw_unioned
    group by dataset, natural_key, lsn

),

raw_stats as (

    select
        dataset,
        sum(delivery_count)                                            as raw_event_count,
        count(*)                                                       as unique_event_count,
        sum(delivery_count) - count(*)                                 as duplicate_event_count,
        sum(case when cdc_operation in ('c', 'r') then 1 else 0 end)    as insert_event_count,
        sum(case when cdc_operation = 'u' then 1 else 0 end)            as update_event_count,
        sum(case when cdc_operation = 'd' then 1 else 0 end)            as delete_event_count
    from raw_grouped
    group by dataset

),

bronze_counts as (

    select 'patients'     as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_patients') }}
    union all
    select 'providers'    as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_providers') }}
    union all
    select 'facilities'   as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_facilities') }}
    union all
    select 'encounters'   as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_encounters') }}
    union all
    select 'diagnoses'    as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_diagnoses') }}
    union all
    select 'procedures'   as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_procedures') }}
    union all
    select 'medications'  as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_medications') }}
    union all
    select 'lab_results'  as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_lab_results') }}
    union all
    select 'observations' as dataset, count(*) as current_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_observations') }}

)

select
    r.dataset,
    r.raw_event_count,
    r.unique_event_count,
    r.duplicate_event_count,
    r.insert_event_count,
    r.update_event_count,
    r.delete_event_count,
    -- Rates, all as a percentage of raw_event_count. These four sum to
    -- ~100% by construction: every raw event is either a duplicate
    -- delivery, or the (exactly one) insert/update/delete event it
    -- duplicates — raw_event_count = unique_event_count + duplicate_event_count,
    -- and unique_event_count = insert + update + delete counts.
    round(100.0 * r.duplicate_event_count / nullif(r.raw_event_count, 0), 2) as duplicate_rate_pct,
    round(100.0 * r.insert_event_count    / nullif(r.raw_event_count, 0), 2) as insert_rate_pct,
    round(100.0 * r.update_event_count    / nullif(r.raw_event_count, 0), 2) as update_rate_pct,
    round(100.0 * r.delete_event_count    / nullif(r.raw_event_count, 0), 2) as delete_rate_pct,
    b.current_row_count,
    b.bronze_deleted_count
from raw_stats r
join bronze_counts b on b.dataset = r.dataset
order by r.dataset
