{#
  CDC reliability engine.

  Debezium's unwrap SMT (see infra-setup/debezium-server-conf/application.properties)
  flattens each change event and adds five fields we rely on here:
    __op             insert / update / delete ('c' / 'u' / 'd', or 'r' for a
                      snapshot read)
    __table          source table name
    __source_ts_ns   the source database's commit timestamp, in nanoseconds —
                      informational event time, NOT used for ordering (see below)
    __source_lsn     the source WAL log sequence number this change was
                      written at — our ordering key
    __db             source database name

  Why LSN, not the commit timestamp: __source_ts_ns is a transaction commit
  timestamp, and Postgres commits are only timestamped once per transaction —
  two updates to the same row inside one transaction get the *same*
  __source_ts_ns. Ordering on it needs a tie-breaker or it's nondeterministic.
  __source_lsn doesn't have that problem: Postgres assigns a distinct,
  strictly increasing LSN to every WAL record, including each row-level
  change within a single transaction, so it's a total order over CDC events
  even at sub-transaction granularity.

  The raw Iceberg table this reads from is an append-only event log
  (debezium.sink.iceberg.upsert=false) — every change event is preserved,
  not just the latest per key — so replay/audit/forensic lineage work off
  the actual CDC history, not a current-state projection that's already lost
  it. cdc_reliable_select() is what turns that at-least-once, unbounded
  event log into "the current state of each row", handling:

    - idempotency / deduplication: collapse multiple events for the same key
      within a batch down to the newest one (by LSN), so replaying a batch
      (in whole or in part, e.g. after an outage) never double-applies a
      change.
    - ordering: never let an event with a lower LSN than what's already
      merged for a key overwrite it — an out-of-order delivery becomes a
      no-op rather than silently reverting the row.
    - deletes: recorded as `is_deleted = true` rather than a physical row
      removal, so downstream consumers and auditors can still answer "what
      happened to this record and when", instead of the row just vanishing.

  Combined with materialized='incremental' + incremental_strategy='merge' and
  unique_key=<natural key>, this makes each dbt run of a bronze model
  idempotent: reprocessing the same CDC offset range twice converges to the
  same table state instead of drifting.

  Lineage (record_token / source_event_id / pipeline_run_id — see
  macros/lineage.sql) is computed once, here, at ingestion into the current-
  state projection, keyed on the natural key and the LSN of the event that
  produced this version of the row. Downstream layers inherit it via
  `select *` rather than recomputing it.
#}

{% macro cdc_reliable_select(source_name, table_name, natural_key_alias, source_columns, column_list) %}

with source_raw as (

    select
        {{ source_columns }},
        __op            as cdc_operation,
        __table         as cdc_source_table,
        __source_ts_ns  as cdc_source_ts_ns,
        __source_lsn    as cdc_source_lsn,
        __db            as cdc_source_db
    from {{ source(source_name, table_name) }}

),

ranked as (

    select
        {{ column_list }},
        cdc_operation,
        cdc_source_table,
        cdc_source_ts_ns,
        cdc_source_lsn,
        cdc_source_db,
        row_number() over (
            partition by {{ natural_key_alias }}
            order by cdc_source_lsn desc
        ) as _rn
    from source_raw

),

deduplicated as (

    select
        {{ column_list }},
        cdc_operation,
        cdc_source_table,
        cdc_source_ts_ns,
        cdc_source_lsn,
        cdc_source_db
    from ranked
    where _rn = 1

)

select
    {{ column_list }},
    cdc_operation,
    (cdc_operation = 'd') as is_deleted,
    cdc_source_table,
    cdc_source_ts_ns,
    cdc_source_lsn,
    cdc_source_db,
    {{ dbt.current_timestamp() }} as _loaded_at,
    {{ lineage_columns('d.' ~ natural_key_alias, 'd.cdc_source_lsn') }}
from deduplicated d
{% if is_incremental() %}
where d.cdc_source_lsn > (
    -- Reliability / ordering: never let an event with a lower LSN than
    -- what's already merged for this key overwrite it. Out-of-order
    -- delivery becomes a no-op instead of silent corruption.
    select coalesce(max(existing.cdc_source_lsn), -1)
    from {{ this }} existing
    where existing.{{ natural_key_alias }} = d.{{ natural_key_alias }}
)
{% endif %}

{% endmacro %}
