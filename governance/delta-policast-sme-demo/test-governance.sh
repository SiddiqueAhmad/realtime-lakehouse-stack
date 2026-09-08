#!/usr/bin/env bash
set -euo pipefail

compose=(docker compose)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

psql_cmd() {
  "${compose[@]}" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U governance -d governance "$@"
}

run_principal() {
  local principal="$1"
  "${compose[@]}" run --rm governed-query "$principal" 2>&1
}

assert_row() {
  local output="$1" id="$2"
  grep -Eq "^\|[[:space:]]*${id}[[:space:]]*\|" <<<"$output" \
    || fail "expected patient row ${id}"
}

assert_no_row() {
  local output="$1" id="$2"
  if grep -Eq "^\|[[:space:]]*${id}[[:space:]]*\|" <<<"$output"; then
    fail "did not expect patient row ${id}"
  fi
}

assert_contains() {
  local output="$1" needle="$2"
  grep -Fq -- "$needle" <<<"$output" || fail "expected output to contain: $needle"
}

restore_state() {
  if [[ -n "${ORIGINAL_POLICY_B64:-}" ]]; then
    psql_cmd -c "UPDATE governance.policies SET cedar = convert_from(decode('${ORIGINAL_POLICY_B64}','base64'),'UTF8') WHERE policy_key='row_filter_region';" >/dev/null || true
  fi
  if [[ -n "${ORIGINAL_ATTRS_B64:-}" ]]; then
    psql_cmd -c "UPDATE governance.principals SET attributes = convert_from(decode('${ORIGINAL_ATTRS_B64}','base64'),'UTF8')::jsonb WHERE principal_key='analyst';" >/dev/null || true
  fi
}
trap restore_state EXIT

echo "==> Starting demo dependencies"
"${compose[@]}" up -d postgres minio
"${compose[@]}" run --rm minio-init >/dev/null

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> Building governed-query"
  "${compose[@]}" build governed-query
fi

# Save state so the destructive fail-closed tests can always restore it.
ORIGINAL_POLICY_B64="$(psql_cmd -At -c "SELECT replace(encode(convert_to(cedar,'UTF8'),'base64'), E'\\n','') FROM governance.policies WHERE policy_key='row_filter_region';")"
ORIGINAL_ATTRS_B64="$(psql_cmd -At -c "SELECT replace(encode(convert_to(attributes::text,'UTF8'),'base64'), E'\\n','') FROM governance.principals WHERE principal_key='analyst';")"

# Normalize the baseline regardless of a previous manual hot-change test.
psql_cmd -c "UPDATE governance.principals SET attributes = jsonb_set(attributes, '{region}', '\"us-east\"'::jsonb, true) WHERE principal_key='analyst';" >/dev/null

echo "==> 1/8 admin: broad rows, no masks, legal hold denied"
out="$(run_principal admin)"
for id in 1001 1002 1003 1004 1006; do assert_row "$out" "$id"; done
assert_no_row "$out" 1005
assert_contains "$out" "123-45-6789"
if grep -Fq '| *** |' <<<"$out"; then fail "admin should not be masked"; fi

echo "==> 2/8 physician: own rows only, no masks"
out="$(run_principal physician)"
assert_row "$out" 1001
assert_row "$out" 1003
for id in 1002 1004 1005 1006; do assert_no_row "$out" "$id"; done
assert_contains "$out" "123-45-6789"

echo "==> 3/8 analyst: regional rows + masks + legal-hold deny"
out="$(run_principal analyst)"
for id in 1001 1003 1006; do assert_row "$out" "$id"; done
for id in 1002 1004 1005; do assert_no_row "$out" "$id"; done
assert_contains "$out" "| *** | ***"

echo "==> 4/8 unknown principal fails before data access"
if out="$(run_principal hacker)"; then
  fail "unknown principal unexpectedly succeeded"
fi
assert_contains "$out" "ACCESS_DENIED: unknown principal"

echo "==> 5/8 malformed bound policy fails closed"
psql_cmd -c "UPDATE governance.policies SET cedar='this is invalid cedar' WHERE policy_key='row_filter_region';" >/dev/null
if out="$(run_principal analyst)"; then
  fail "malformed Cedar unexpectedly succeeded"
fi
assert_contains "$out" "parse Cedar policy row_filter_region"
psql_cmd -c "UPDATE governance.policies SET cedar = convert_from(decode('${ORIGINAL_POLICY_B64}','base64'),'UTF8') WHERE policy_key='row_filter_region';" >/dev/null

echo "==> 6/8 hot principal attribute change requires no rebuild"
psql_cmd -c "UPDATE governance.principals SET attributes = jsonb_set(attributes, '{region}', '\"us-west\"'::jsonb, true) WHERE principal_key='analyst';" >/dev/null
out="$(run_principal analyst)"
assert_row "$out" 1002
for id in 1001 1003 1004 1005 1006; do assert_no_row "$out" "$id"; done
assert_contains "$out" "| *** | ***"

echo "==> 7/8 brand-new principal attribute works with policy-only change"
psql_cmd -c "UPDATE governance.principals SET attributes = jsonb_set(attributes, '{doctor_scope}', '\"Dr. Smith\"'::jsonb, true) WHERE principal_key='analyst';" >/dev/null
psql_cmd >/dev/null <<'SQL'
UPDATE governance.policies
SET cedar = $cedar$
@id("row_filter_region")
@filter_type("row_filter")
@target_table("patients")
permit (
    principal,
    action == Action::"query",
    resource
)
when {
    resource.treating_physician == principal.doctor_scope
};
$cedar$
WHERE policy_key = 'row_filter_region';
SQL
out="$(run_principal analyst)"
assert_row "$out" 1001
assert_row "$out" 1003
for id in 1002 1004 1005 1006; do assert_no_row "$out" "$id"; done
assert_contains "$out" "| *** | ***"

echo "==> 8/8 missing dynamic attribute fails closed"
psql_cmd -c "UPDATE governance.principals SET attributes = attributes - 'doctor_scope' WHERE principal_key='analyst';" >/dev/null
if out="$(run_principal analyst)"; then
  fail "missing required principal attribute unexpectedly succeeded"
fi
assert_contains "$out" "ACCESS_DENIED"
assert_contains "$out" "doctor_scope"

restore_state
trap - EXIT

echo
echo "PASS: all governance regression tests passed"
