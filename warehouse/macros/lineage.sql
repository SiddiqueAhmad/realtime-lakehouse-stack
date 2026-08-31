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
  is brute-forceable in a fraction of a second.

  v4 (this version): the HMAC itself is computed by hmac_sha256_hex(), a
  Python UDF registered by warehouse/duckdb_plugins/lineage_udfs.py — DuckDB
  has sha256() but no built-in keyed HMAC, unlike Trino. That UDF reads
  RECORD_TOKEN_HMAC_KEY straight from the process environment, which is
  also a real security improvement over the v2/v3 (Trino) design: the key
  never gets templated into compiled SQL text the way env_var() used to
  inline it, so it can no longer leak into a query log or dbt's target/
  artifacts. See docs/lineage_token_rotation.md's v3 -> v4 entry and
  duckdb_plugins/lineage_udfs.py's own docstring for the full rationale.
  RECORD_TOKEN_HMAC_KEY itself is still set the same way (env var, with the
  same obviously-fake dev-only fallback for local/CI runs — see that
  plugin's _DEV_ONLY_KEY).
#}

{% macro generate_record_token(table_expr, natural_key_expr, tenant='ehr') %}
    -- Keyed, non-reversible per-row token: same (tenant, table, natural
    -- key) under the same key always produces the same token, so it can be
    -- used to correlate a row across bronze/silver/quarantine without
    -- re-exposing the source identifier — but, unlike an unkeyed hash,
    -- isn't brute-forceable back to a sequential integer patient_id.
    --
    -- table_expr is load-bearing, not decoration: every entity here uses
    -- small sequential integer keys starting near 1, so patient_id=1 and
    -- encounter_id=1 exist simultaneously. Without the table in the hash
    -- input, those would produce the SAME record_token — invisible within
    -- any single entity's own bronze/silver/quarantine chain (which only
    -- ever joins against other tables of that same entity), but wrong the
    -- moment something correlates record_token across entities, e.g.
    -- models/gold/record_lineage.sql's cross-entity union.
    ('r_v4_' || substr(
        hmac_sha256_hex(
            '{{ tenant }}:' || cast({{ table_expr }} as varchar) || ':' || cast({{ natural_key_expr }} as varchar)
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
    ('evt_v3_' || substr(
        hmac_sha256_hex(
            '{{ tenant }}:' ||
            cast({{ table_expr }} as varchar) || ':' ||
            cast({{ natural_key_expr }} as varchar) || ':' ||
            coalesce(cast({{ tx_id_expr }} as varchar), 'snapshot') || ':' ||
            coalesce(cast({{ tx_total_order_expr }} as varchar), cast({{ lsn_expr }} as varchar))
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
    {{ generate_record_token(table_expr, natural_key_expr) }} as record_token,
    {{ generate_source_event_id(table_expr, natural_key_expr, tx_id_expr, tx_total_order_expr, lsn_expr) }} as source_event_id,
    {{ pipeline_run_id() }}                                    as pipeline_run_id
{% endmacro %}

{% macro record_lineage_event_decision_transition(previous_quality_status_expr, previous_is_trusted_expr, quality_status_expr, is_trusted_expr) %}
    -- Factored out of models/gold/record_lineage_event.sql's final SELECT
    -- for the same reason record_lineage_event_decision_fingerprint() below
    -- was: this value is now also needed BEFORE the allocator call (folded
    -- into the JSON payload record_lineage_event_payload_json() stages for
    -- reconciliation - see lineage_seq_udf.py), not just in the model's own
    -- output column, so it has to be computed once and reused, not
    -- recomputed twice from possibly-drifted copies of the same CASE logic.
    coalesce(
        case
            when {{ previous_quality_status_expr }} = 'DELETED' then 'DELETED'
            when {{ previous_quality_status_expr }} is not null then
                {{ previous_quality_status_expr }} || '/' ||
                    (case when {{ previous_is_trusted_expr }} then 'trusted' else 'quarantined' end)
        end,
        '(new)'
    ) || ' -> ' ||
        case
            when {{ quality_status_expr }} = 'DELETED' then 'DELETED'
            else {{ quality_status_expr }} || '/' || (case when {{ is_trusted_expr }} then 'trusted' else 'quarantined' end)
        end
{% endmacro %}

{% macro record_lineage_event_payload_json(dataset_expr, source_event_id_expr, pipeline_run_id_expr, cdc_operation_expr, quality_status_expr, failed_checks_expr, is_trusted_expr, is_quarantined_expr, previous_decision_fingerprint_expr, decision_transition_expr, logged_at_expr) %}
    -- The durable "what record_lineage_event.sql's own INSERT is about to
    -- write for this decision" snapshot - everything that model's final
    -- SELECT produces for one row, EXCEPT record_token, event_sequence,
    -- decision_fingerprint and ledger_key, which the allocator/outbox
    -- already carries as first-class columns of its own (see
    -- lineage_seq_udf.py's _ALLOCATE_IF_NEW and its outbox table's
    -- columns) and so would be redundant to duplicate inside the JSON.
    -- Passed to next_event_sequence_if_new() as this decision's payload,
    -- staged into lineage_seq.record_lineage_event_outbox atomically
    -- alongside the allocation itself - see that module's docstring for
    -- why: if the surrounding dbt run's own INSERT into this table never
    -- lands (crash, failure), infra-setup/scripts/lineage_ledger_reconciliation.py
    -- reconstructs the exact row that was supposed to be logged straight
    -- from this JSON, rather than having to (incorrectly) recompute it from
    -- record_lineage's CURRENT state, which may have moved on by the time
    -- reconciliation runs.
    to_json(struct_pack(
        dataset := {{ dataset_expr }},
        source_event_id := {{ source_event_id_expr }},
        pipeline_run_id := {{ pipeline_run_id_expr }},
        cdc_operation := {{ cdc_operation_expr }},
        quality_status := {{ quality_status_expr }},
        failed_checks := {{ failed_checks_expr }},
        is_trusted := {{ is_trusted_expr }},
        is_quarantined := {{ is_quarantined_expr }},
        previous_decision_fingerprint := {{ previous_decision_fingerprint_expr }},
        decision_transition := {{ decision_transition_expr }},
        -- strftime to a fixed, explicit format rather than letting to_json()
        -- pick its own TIMESTAMP -> string rendering: infra-setup/scripts/
        -- lineage_ledger_reconciliation.py has to parse this same string
        -- back out on the Python side to replay it as a TIMESTAMP literal,
        -- and pinning the format here is what keeps those two sides from
        -- ever silently drifting apart.
        logged_at := strftime({{ logged_at_expr }}, '%Y-%m-%d %H:%M:%S.%f')
    ))
{% endmacro %}

{% macro record_lineage_event_decision_fingerprint(record_token_expr, source_event_id_expr, quality_status_expr, failed_checks_expr, is_trusted_expr, is_quarantined_expr) %}
    -- Deterministic hash of exactly the fields models/gold/record_lineage_event.sql's
    -- own change-detection compares on. Factored out into one macro (rather
    -- than inlined separately in that model's seed branch, incremental
    -- branch, and final SELECT, as earlier versions did) specifically so
    -- next_event_sequence_if_new() - which needs this SAME fingerprint
    -- value as an input, computed once, before the model's own final
    -- SELECT - can never drift from what actually gets stored in the
    -- decision_fingerprint column. See that model's own docstring/
    -- CONCURRENCY CONTRACT comment for why the fingerprint has to be
    -- computed before, not after, the atomic allocation check.
    sha256(
        {{ record_token_expr }} || ':' ||
        coalesce({{ source_event_id_expr }}, '') || ':' ||
        {{ quality_status_expr }} || ':' ||
        coalesce({{ failed_checks_expr }}, '') || ':' ||
        cast({{ is_trusted_expr }} as varchar) || ':' ||
        cast({{ is_quarantined_expr }} as varchar)
    )
{% endmacro %}
