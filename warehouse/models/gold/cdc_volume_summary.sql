{{ config(materialized='table', schema='gold', tags=['gold', 'observability']) }}

-- Volume and dedup/redelivery ratio, per entity: how many raw CDC events
-- (the immutable append-only log — see debezium.sink.iceberg.upsert=false
-- in infra-setup/debezium-server-conf/application.properties) does the
-- reliability engine collapse into each current-state row in bronze?
-- Counts only — no PHI-classified column is read or emitted.

with raw_counts as (

    select 'patients'     as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_patients') }}
    union all
    select 'providers'    as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_providers') }}
    union all
    select 'facilities'   as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_facilities') }}
    union all
    select 'encounters'   as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_encounters') }}
    union all
    select 'diagnoses'    as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_diagnoses') }}
    union all
    select 'procedures'   as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_procedures') }}
    union all
    select 'medications'  as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_medications') }}
    union all
    select 'lab_results'  as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_lab_results') }}
    union all
    select 'observations' as dataset, count(*) as raw_event_count from {{ source('ehr', 'debeziumcdc_dbz__ehr_observations') }}

),

bronze_counts as (

    select 'patients'     as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_patients') }}
    union all
    select 'providers'    as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_providers') }}
    union all
    select 'facilities'   as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_facilities') }}
    union all
    select 'encounters'   as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_encounters') }}
    union all
    select 'diagnoses'    as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_diagnoses') }}
    union all
    select 'procedures'   as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_procedures') }}
    union all
    select 'medications'  as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_medications') }}
    union all
    select 'lab_results'  as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_lab_results') }}
    union all
    select 'observations' as dataset, count(*) as bronze_row_count, count(*) filter (where is_deleted) as bronze_deleted_count from {{ ref('br_observations') }}

)

select
    r.dataset,
    r.raw_event_count,
    b.bronze_row_count,
    b.bronze_deleted_count,
    -- Events collapsed per current-state row: 1.0 means "one event per row
    -- so far" (a fresh snapshot); higher means more updates/redeliveries
    -- per key have been absorbed by the reliability engine without
    -- inflating bronze. A ratio that trends toward 1.0 over time on a
    -- table that should see steady updates is itself a signal worth
    -- investigating (are updates actually arriving?).
    round(cast(r.raw_event_count as double) / nullif(b.bronze_row_count, 0), 2) as events_per_current_row
from raw_counts r
join bronze_counts b on r.dataset = b.dataset
order by r.dataset
