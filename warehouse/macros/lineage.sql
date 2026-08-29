{#
  Lineage helpers.

  Operational lineage must be safe to log, alert on, and store outside the
  PHI access boundary. That means: controlled, non-reversible identifiers —
  never raw patient values. See governance/phi_classification.yml
  ("lineage_safety_rules").
#}

{% macro generate_record_token(natural_key_expr) %}
    -- Deterministic, non-reversible per-row token. Same natural key always
    -- produces the same token, so it can be used to correlate a row across
    -- bronze/silver/quarantine without re-exposing the source identifier.
    ('r_' || substr(to_hex(md5(to_utf8(cast({{ natural_key_expr }} as varchar)))), 1, 16))
{% endmacro %}

{% macro generate_source_event_id(natural_key_expr, source_ts_ns_expr) %}
    -- Identifies one specific CDC event (a natural key at a point in source
    -- time), distinct from record_token which identifies the row's current
    -- identity. Two different events for the same row get different ids.
    ('evt_' || substr(to_hex(md5(to_utf8(cast({{ natural_key_expr }} as varchar) || ':' || cast({{ source_ts_ns_expr }} as varchar)))), 1, 16))
{% endmacro %}

{% macro pipeline_run_id() %}
    -- One id per dbt invocation, so every row built in a run can be traced
    -- back to that run without carrying anything patient-specific.
    'run_{{ invocation_id }}'
{% endmacro %}

{% macro lineage_columns(natural_key_expr, source_ts_ns_expr) %}
    {{ generate_record_token(natural_key_expr) }}     as record_token,
    {{ generate_source_event_id(natural_key_expr, source_ts_ns_expr) }} as source_event_id,
    {{ pipeline_run_id() }}                            as pipeline_run_id
{% endmacro %}
