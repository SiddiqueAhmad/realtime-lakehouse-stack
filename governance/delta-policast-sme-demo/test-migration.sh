#!/usr/bin/env bash
# Tests ONLY schema migrations in a new scratch database. Normal data is untouched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
compose=(docker compose -f docker-compose.yml)
test_db="governance_migration_test_$(date +%s)_$$"
created=0
pg() {
  "${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U governance -d "$test_db" "$@"
}
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$created" == 1 ]]; then
    if ! "${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U governance -d postgres \
      -c "DROP DATABASE \"$test_db\";" >/dev/null; then
      echo "Could not remove scratch database $test_db" >&2; rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${compose[@]}" exec -T postgres psql -X -v ON_ERROR_STOP=1 -U governance -d postgres \
  -c "CREATE DATABASE \"$test_db\";" >/dev/null
created=1
pg >/dev/null <<'SQL'
CREATE SCHEMA governance;
CREATE TABLE governance.principals (
    principal_key text PRIMARY KEY, role text NOT NULL, region text, display_name text
);
INSERT INTO governance.principals VALUES
    ('admin','admin',NULL,'Platform Admin'),
    ('analyst','analyst','us-west','Healthcare Analyst'),
    ('physician','physician',NULL,'Dr. Smith');
CREATE TABLE governance.policies (
    policy_key text PRIMARY KEY, cedar text NOT NULL,
    enabled boolean NOT NULL DEFAULT true, updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO governance.policies(policy_key,cedar,enabled) VALUES
    ('row_filter_region','unchanged region policy',true),
    ('row_filter_physician','unchanged physician policy',true),
    ('mask_ssn','unchanged ssn policy',false),
    ('mask_diagnosis','unchanged diagnosis policy',true),
    ('deny_legal_hold','unchanged legal-hold policy',true);
CREATE TABLE public.saved_policies AS SELECT * FROM governance.policies;
CREATE TABLE public.unrelated_data(value integer);
INSERT INTO public.unrelated_data VALUES (42);
SQL
pg < postgres/migrations/001_dynamic_governance.sql >/dev/null
pg >/dev/null <<'SQL'
DO $$
BEGIN
    IF (SELECT attributes->>'region' FROM governance.principals WHERE principal_key='analyst') IS DISTINCT FROM 'us-west' THEN
        RAISE EXCEPTION 'legacy region was not preserved';
    END IF;
    IF (SELECT attributes FROM governance.principals WHERE principal_key='admin') IS DISTINCT FROM '{}'::jsonb THEN
        RAISE EXCEPTION 'null legacy region should yield empty attributes';
    END IF;
    IF (SELECT count(*) FROM governance.principals) <> 3 THEN RAISE EXCEPTION 'principal rows changed'; END IF;
    IF EXISTS ((SELECT * FROM governance.policies EXCEPT SELECT * FROM public.saved_policies)
               UNION ALL (SELECT * FROM public.saved_policies EXCEPT SELECT * FROM governance.policies)) THEN
        RAISE EXCEPTION 'policies changed';
    END IF;
    IF (SELECT count(*) FROM governance.policy_bindings) <> 5 THEN RAISE EXCEPTION 'expected five legacy bindings'; END IF;
    IF (SELECT principal_selector FROM governance.policy_bindings WHERE binding_id='bind_region_analyst') IS DISTINCT FROM 'role:analyst' THEN
        RAISE EXCEPTION 'regional binding is incorrect';
    END IF;
    IF (SELECT enabled FROM governance.policy_bindings WHERE binding_id='bind_mask_ssn_global') IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'disabled policy became enabled';
    END IF;
    IF (SELECT value FROM public.unrelated_data) IS DISTINCT FROM 42 THEN RAISE EXCEPTION 'unrelated data changed'; END IF;
END;
$$;
UPDATE governance.principals SET attributes='{"region":"eu-west","branch":"Lahore"}' WHERE principal_key='analyst';
DELETE FROM governance.policy_bindings WHERE binding_id='bind_region_analyst';
UPDATE governance.policy_bindings SET enabled=false WHERE binding_id='bind_legal_hold_global';
SQL
echo 'PASS: legacy upgrade preserves identities, policies and unrelated data'
pg < postgres/migrations/001_dynamic_governance.sql >/dev/null
pg >/dev/null <<'SQL'
DO $$
BEGIN
    IF (SELECT attributes FROM governance.principals WHERE principal_key='analyst') IS DISTINCT FROM '{"region":"eu-west","branch":"Lahore"}'::jsonb THEN
        RAISE EXCEPTION 'rerun overwrote dynamic attributes';
    END IF;
    IF EXISTS (SELECT 1 FROM governance.policy_bindings WHERE binding_id='bind_region_analyst') THEN RAISE EXCEPTION 'rerun resurrected binding'; END IF;
    IF (SELECT enabled FROM governance.policy_bindings WHERE binding_id='bind_legal_hold_global') IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'rerun re-enabled binding';
    END IF;
END;
$$;
SQL
echo 'PASS: legacy migration rerun is a no-op'
# Recreate ONLY the scratch schema, then explicitly load the example fixture.
pg -c 'DROP SCHEMA governance CASCADE;' >/dev/null
pg < postgres/init.sql >/dev/null
pg < postgres/migrations/002_table_registry.sql >/dev/null
pg < fixtures/healthcare/governance.sql >/dev/null
pg >/dev/null <<'SQL'
UPDATE governance.principals SET attributes='{"region":"us-west","custom":"keep"}' WHERE principal_key='analyst';
DELETE FROM governance.policy_bindings WHERE binding_id='bind_region_analyst';
UPDATE governance.tables SET enabled=false WHERE table_key='patients';
SQL
pg < postgres/migrations/001_dynamic_governance.sql >/dev/null
pg < postgres/migrations/002_table_registry.sql >/dev/null
pg >/dev/null <<'SQL'
DO $$
BEGIN
    IF (SELECT attributes FROM governance.principals WHERE principal_key='analyst') IS DISTINCT FROM '{"region":"us-west","custom":"keep"}'::jsonb THEN
        RAISE EXCEPTION 'migration changed already-dynamic attributes';
    END IF;
    IF EXISTS (SELECT 1 FROM governance.policy_bindings WHERE binding_id='bind_region_analyst') THEN RAISE EXCEPTION 'migration restored binding'; END IF;
    IF (SELECT enabled FROM governance.tables WHERE table_key='patients') IS DISTINCT FROM false THEN RAISE EXCEPTION 'migration re-enabled table'; END IF;
END;
$$;
SQL
echo 'PASS: dynamic schema and registry state survive migration reruns'
echo 'PASS: migration regression tests passed'
