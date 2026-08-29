{#
  Lineage helpers.

  Operational lineage must be safe to log, alert on, and store outside the
  PHI access boundary. That means: controlled, keyed identifiers — never raw
  patient values, and never a token a natural key can be brute-forced back
  out of. See governance/phi_classification.yml ("lineage_safety_rules") and
  docs/lineage_token_rotation.md.

  Tokens are HMAC-SHA256(secret, tenant || ':' || natural_key), keyed by
  RECORD_TOKEN_HMAC_KEY. A plain hash of the natural key is NOT safe here:
  patient_id and friends are small sequential integers, so an unkeyed hash
  is brute-forceable in a fraction of a second. Set RECORD_TOKEN_HMAC_KEY in
  the environment dbt runs in (a secrets manager in any real deployment) —
  never commit it. The fallback below is an obviously-fake dev-only key so
  local/CI runs work without one, and is not fit for anything containing
  real PHI-shaped data beyond this repo's synthetic fixtures.
#}

{% macro _record_token_hmac_key() %}
{{ return(env_var('RECORD_TOKEN_HMAC_KEY', 'dev-only-insecure-key-DO-NOT-USE-IN-PRODUCTION')) }}
{% endmacro %}

{% macro generate_record_token(natural_key_expr, tenant='ehr') %}
    -- Keyed, non-reversible per-row token: same (tenant, natural key) under
    -- the same key always produces the same token, so it can be used to
    -- correlate a row across bronze/silver/quarantine without re-exposing
    -- the source identifier — but, unlike an unkeyed hash, isn't
    -- brute-forceable back to a sequential integer patient_id.
    ('r_v1_' || substr(
        to_hex(
            hmac_sha256(
                to_utf8('{{ tenant }}:' || cast({{ natural_key_expr }} as varchar)),
                to_utf8('{{ _record_token_hmac_key() }}')
            )
        ),
        1, 16
    ))
{% endmacro %}

{% macro generate_source_event_id(natural_key_expr, source_position_expr, tenant='ehr') %}
    -- Identifies one specific CDC event (a natural key at a specific,
    -- globally-ordered source position — see cdc_source_lsn), distinct from
    -- record_token which identifies the row's current identity. Two
    -- different events for the same row get different ids. Same keying
    -- rationale as generate_record_token.
    ('evt_v1_' || substr(
        to_hex(
            hmac_sha256(
                to_utf8('{{ tenant }}:' || cast({{ natural_key_expr }} as varchar) || ':' || cast({{ source_position_expr }} as varchar)),
                to_utf8('{{ _record_token_hmac_key() }}')
            )
        ),
        1, 16
    ))
{% endmacro %}

{% macro pipeline_run_id() %}
    -- One id per dbt invocation, so every row built in a run can be traced
    -- back to that run without carrying anything patient-specific.
    'run_{{ invocation_id }}'
{% endmacro %}

{% macro lineage_columns(natural_key_expr, source_position_expr) %}
    {{ generate_record_token(natural_key_expr) }}     as record_token,
    {{ generate_source_event_id(natural_key_expr, source_position_expr) }} as source_event_id,
    {{ pipeline_run_id() }}                            as pipeline_run_id
{% endmacro %}
