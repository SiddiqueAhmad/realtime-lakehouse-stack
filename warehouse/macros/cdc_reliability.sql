{#
  CDC reliability engine.

  Debezium's unwrap SMT (see infra-setup/debezium-server-conf/application.properties)
  flattens each change event and adds four fields we rely on here:
    __op             insert / update / delete ('c' / 'u' / 'd', or 'r' for a
                      snapshot read)
    __table          source table name
    __source_ts_ns   the source database's commit timestamp, in nanoseconds —
                      our event-time / ordering key
    __db             source database name

  cdc_reliable_select() turns a raw, at-least-once, possibly-out-of-order CDC
  stream into a table that is safe to treat as "the current state of each
  row", by handling:

    - idempotency / deduplication: collapse multiple events for the same key
      within a batch down to the newest one, so replaying a batch (in whole
      or in part, e.g. after an outage) never double-applies a change.
    - ordering: never let an event older (by source commit time) than what
      is already merged for a key overwrite it — an out-of-order delivery
      becomes a no-op rather than silently reverting the row.
    - deletes: a delete is recorded as `is_deleted = true` rather than a
      physical row removal, so downstream consumers and auditors can still
      answer "what happened to this record and when", instead of the row
      just vanishing.

  Combined with materialized='incremental' + incremental_strategy='merge' and
  unique_key=<natural key>, this makes each dbt run of a bronze model
  idempotent: reprocessing the same CDC offset range twice converges to the
  same table state instead of drifting.
#}

{% macro cdc_reliable_select(source_name, table_name, natural_key_alias, source_columns, column_list) %}

with source_raw as (

    select
        {{ source_columns }},
        __op            as cdc_operation,
        __table         as cdc_source_table,
        __source_ts_ns  as cdc_source_ts_ns,
        __db            as cdc_source_db
    from {{ source(source_name, table_name) }}

),

ranked as (

    select
        {{ column_list }},
        cdc_operation,
        cdc_source_table,
        cdc_source_ts_ns,
        cdc_source_db,
        row_number() over (
            partition by {{ natural_key_alias }}
            order by cdc_source_ts_ns desc
        ) as _rn
    from source_raw

),

deduplicated as (

    select
        {{ column_list }},
        cdc_operation,
        cdc_source_table,
        cdc_source_ts_ns,
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
    cdc_source_db,
    {{ dbt.current_timestamp() }} as _loaded_at
from deduplicated d
{% if is_incremental() %}
where d.cdc_source_ts_ns > (
    select coalesce(max(existing.cdc_source_ts_ns), -1)
    from {{ this }} existing
    where existing.{{ natural_key_alias }} = d.{{ natural_key_alias }}
)
{% endif %}

{% endmacro %}
