{#
  Lineage helpers.

  Operational lineage must be safe to log, alert on, and store outside the
  PHI access boundary. That means: controlled, keyed identifiers — never raw
  patient values, and never a token a natural key can be brute-forced back
  out of. See governance/phi_classification.yml ("lineage_safety_rules") and
  docs/lineage_token_rotation.md.

  Tokens are HMAC-SHA256(secret, ...), truncated to 128 bits (32 hex chars —
  enough that truncation isn't the weak point; the key is), keyed by
  RECORD_TOKEN_HMAC_KEY. A plain hash of the natural key is NOT safe here:
  patient_id and friends are small sequential integers, so an unkeyed hash
  is brute-forceable in a fraction of a second. Set RECORD_TOKEN_HMAC_KEY in
  the environment dbt runs in (a secrets manager in any real deployment) —
  never commit it. The fallback below is an obviously-fake dev-only key so
  local/CI runs work without one, and is not fit for anything containing
  real PHI-shaped data beyond this repo's synthetic fixtures.

  KNOWN LIMITATION: dbt resolves env_var() at compile time and inlines the
  literal key into the SQL text sent to Trino, so the key itself — not just
  the tokens it produces — can end up in compiled SQL, Trino's query log,
  and dbt's own logs/target/ artifacts. That's an acceptable tradeoff for
  this repo's synthetic data, but a deployment handling real ePHI should
  move this computation into a catalog-side function or UDF the key never
  has to leave, rather than templating it into every query. See
  docs/lineage_token_rotation.md.
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
    ('r_v2_' || substr(
        to_hex(
            hmac_sha256(
                to_utf8('{{ tenant }}:' || cast({{ natural_key_expr }} as varchar)),
                to_utf8('{{ _record_token_hmac_key() }}')
            )
        ),
        1, 32
    ))
{% endmacro %}

{% macro generate_source_event_id(table_expr, natural_key_expr, tx_id_expr, tx_total_order_expr, lsn_expr, tenant='ehr') %}
    -- Identifies one specific CDC event, keyed on more than just (natural
    -- key, LSN): Debezium's transaction metadata (tx_id, total_order — see
    -- infra-setup/debezium-server-conf/application.properties'
    -- provide.transaction.metadata) places the event within its source
    -- transaction, which LSN alone doesn't capture on its own as a fingerprint
    -- (LSN *is* still what cdc_reliable_select orders/merges on — it's the
    -- correct, simplest choice for "is this newer than what I already have",
    -- a total order across the whole WAL; transaction metadata is about event
    -- *identity/fingerprint* for audit and forensic replay, not ordering).
    -- tx_id/tx_total_order are null for snapshot ('r') events, which aren't
    -- part of a streamed transaction — LSN (always present, unique per row
    -- even in a snapshot) covers that case via the coalesce below.
    ('evt_v2_' || substr(
        to_hex(
            hmac_sha256(
                to_utf8(
                    '{{ tenant }}:' ||
                    cast({{ table_expr }} as varchar) || ':' ||
                    cast({{ natural_key_expr }} as varchar) || ':' ||
                    coalesce(cast({{ tx_id_expr }} as varchar), 'snapshot') || ':' ||
                    coalesce(cast({{ tx_total_order_expr }} as varchar), cast({{ lsn_expr }} as varchar))
                ),
                to_utf8('{{ _record_token_hmac_key() }}')
            )
        ),
        1, 32
    ))
{% endmacro %}

{% macro pipeline_run_id() %}
    -- One id per dbt invocation, so every row built in a run can be traced
    -- back to that run without carrying anything patient-specific.
    'run_{{ invocation_id }}'
{% endmacro %}

{% macro lineage_columns(table_expr, natural_key_expr, tx_id_expr, tx_total_order_expr, lsn_expr) %}
    {{ generate_record_token(natural_key_expr) }} as record_token,
    {{ generate_source_event_id(table_expr, natural_key_expr, tx_id_expr, tx_total_order_expr, lsn_expr) }} as source_event_id,
    {{ pipeline_run_id() }}                        as pipeline_run_id
{% endmacro %}
