# Generic governed Delta query demo

Status: a development reference, not a production security gateway. The query
runtime is domain-neutral; healthcare and trading are opt-in fixtures. This
refactor adds new code and tests and must pass the Docker build and regression
suite before merge. Earlier manual demo passes do not validate this revision.

## Boundaries

- PostgreSQL: identities, JSONB string attributes, policy source, bindings,
  source registry and table registry.
- Generic Rust query binary: principal lookup, registry resolution, schema
  discovery from Delta, policy validation, Policast wrapping and read-only SQL.
- Separate `seed-fixture` binary: trusted fixture import from JSON. It is never
  called by the query path. Unknown/missing tables do not trigger seeding.
- `fixtures/healthcare` and `fixtures/trading`: sample schemas, rows, Cedar,
  bindings and queries. No business column or table names are embedded in the
  production Rust paths. Rust test fixtures may use illustrative names.

Only the **Delta adapter** is implemented. The registry is not a claim of working
DuckLake/Postgres-source adapters. Those require separate implementations and tests.
The PostgreSQL service here is the control plane, not the analytical data source.

## Upgrade and run — do not delete your volumes

From this directory:

```bash
bash demo.sh
```

The script runs additive migrations, builds the image (including Rust tests),
imports the two example fixtures, and runs both domains using the same query
binary. Existing Delta tables and existing principal/policy/binding records are
preserved by fixture imports. A previous `us-west` principal change stays in place.

For explicit control:

```bash
bash migrate.sh
# Build the generic query binary and separate fixture-import binary.
docker compose build governed-query
SKIP_BUILD=1 bash seed-demo.sh

docker compose run --rm governed-query analyst \
  --table patients --sql 'SELECT * FROM patients ORDER BY patient_id'

docker compose run --rm governed-query finance_reader \
  --table invoices \
  --sql "SELECT invoice_id, amount_minor, bank_account FROM invoices WHERE status='OPEN'"
```

The old invocation `governed-query analyst` deliberately no longer supplies an
implicit patient table or query. The caller must supply a principal, one or more
`--table TABLE_KEY` registrations, and `--sql SQL` or `--sql-file PATH`. A SQL file
must be mounted into the container when using `--sql-file`.

Append `--format json` for machine-readable results. Diagnostics go to stderr.
Repeated `--table` arguments allow joins across separately authorized registered
Delta tables. Table keys are stable control-plane identifiers; `logical_name` is
the SQL alias. This version restricts aliases to simple lowercase identifiers.

### Schema drift

`postgres/migrations/001_dynamic_governance.sql` preserves legacy regions and
policy text while adding JSONB attributes/bindings. Migration 002 adds the source
and table registry without seeding business metadata. Migrations are separate
from query execution and can be rerun without resetting data.

A missing schema version produces `SCHEMA_MIGRATION_REQUIRED`, not an incorrect
unknown-user error. The existing principal lookup still distinguishes database
failures from genuinely absent principals.

PostgreSQL 18 uses the existing `pgdata:/var/lib/postgresql` mount. No volume
layout change is introduced by this refactor. Do not use `docker compose down -v`
for normal upgrades: that also deletes the Delta files in the MinIO volume.

## Register another existing Delta table

1. Ensure the Delta table already exists at its storage location using a trusted
   ingestion process. The query service will not create it.
2. Register its source/table and create reviewed principal attributes and Cedar.
3. Add explicit bindings, then query it with the same image.

Example metadata (replace the location with your actual Delta table):

```sql
INSERT INTO governance.data_sources(source_key,kind) VALUES ('company-lake','delta');
INSERT INTO governance.tables(table_key,source_key,logical_name,location)
VALUES ('company-orders','company-lake','orders','s3://lake/company/orders');

INSERT INTO governance.policies(policy_key,cedar) VALUES ('orders_scope', $cedar$
@id("orders_scope") @filter_type("row_filter") @target_table("company-orders")
permit(principal,action == Action::"query",resource)
when { resource.company_id == principal.company_id };
$cedar$);

INSERT INTO governance.policy_bindings(binding_id,policy_key,target,principal_selector)
VALUES ('orders_sales','orders_scope','company-orders','role:sales');
```

```bash
docker compose run --rm governed-query alice \
  --table company-orders --sql 'SELECT * FROM orders'
```

`alice` must already exist with the `sales` role and the necessary company_id
string attribute. S3 credentials come from the deployment environment, not SQL,
policy source, fixture rows, or arbitrary caller-provided connection strings.

## Policy changes remain configuration

```sql
UPDATE governance.principals
SET attributes=jsonb_set(attributes,'{region}','"us-west"'::jsonb)
WHERE principal_key='analyst';
```

The next invocation loads a fresh, consistent control-plane snapshot. There is
no long-running query server or policy cache in this demo, and no rebuild is
needed for metadata, binding, or supported policy-expression changes.

New string attributes such as company_id, branch or doctor_scope work through
Policast `AttrIdentity`. Required attributes are validated before opening Delta.
Native numeric/boolean/list principal attributes are not implemented: JSONB
values must be strings. Resource columns retain their Delta/Arrow types.

Bindings select policies by exact table key or `*`, and by `*`, `role:<role>` or
`principal:<key>`. Applicable row constraints compose with AND, followed by deny
constraints; they are not alternative Cedar allow grants combined with OR.
`precedence` remains reserved metadata and does not override these semantics.
Tag expansion and group selectors are not implemented in this reference.

At least one bound **permit row policy** is required per table. Global masks and
deny policies alone do not grant access. The healthcare fixture therefore adds
an explicit admin permit (`when { true }`) rather than relying on an empty filter
set to mean authorized. This is a conservative demo contract, not a full Cedar
Authorizer implementation. Bindings are the assignment authority; avoid keeping
legacy `@roles` annotations as a second assignment mechanism.

## Query safety and current trade-off

Only one read-only query statement is accepted. DDL, DML, COPY/export statements,
session changes and multiple statements are rejected. All requested tables must
be enabled, registered and independently authorized. SQL cannot register a new
source or supply its location. This is not permission to expose the CLI/container
to untrusted users: a production service must authenticate identities rather
than accepting an arbitrary principal argument.

The pinned Policast version has important integration limitations. A conservative
outer `ReadBoundary` preflights row/deny expressions, scans through Policast with
the complete schema, and applies requested projection afterwards. User WHERE,
LIMIT and aggregation remain above governance, and predicates on masked columns
see the masked value, not the original. Missing columns, unsupported row
expressions and inconsistent binding/Cedar targets fail rather than skipping
security filters. String column masks are supported; other mask types are rejected.

This intentionally **disables user filter/limit/projection pushdown below the
security boundary**, so it can scan more data. It is a correctness-first reference,
not a performance benchmark or production hardening claim. Metadata may be read
while constructing table providers. Raw values still exist in the trusted query
process before masking. Storage credentials, engine process access, UDFs, resource
quotas, authenticated APIs and production policy-validation workflows remain
separate security responsibilities.

## Tests

```bash
# Static architecture checks (no Docker needed):
python3 -m unittest discover -s tests -p 'test_layout.py' -v

# Docker build runs existing control-plane tests plus new CLI, registry,
# SQL-boundary and fixture-loader Rust tests:
docker compose build governed-query

# Structured JSON assertions; no parsing pretty table output:
SKIP_BUILD=1 bash test-governance.sh

# Legacy migration preservation, reruns and registry preservation:
bash test-migration.sh
```

The E2E runner requires Python 3.10+. It creates a unique scratch Postgres database
and separate Delta objects under `s3://lake/_governance_tests/<run>/`. It does not
mutate the normal `governance` database or normal fixture tables. The scratch DB
is removed in `finally`; isolated test objects are retained for debugging.

The 20 regression cases cover exact healthcare rows/masks, unknown identities,
malformed policies, runtime attributes, new attributes, missing attributes, a
second unrelated table schema, caller projections/filters, LIMIT, COUNT, CTEs,
masked-value probing, dynamic role/principal bindings, missing columns, invalid
targets, unsupported expressions, write rejection and per-table authorization.
`.github/workflows/governed-delta.yml` runs the static, Rust, E2E and migration
checks for this demo's PR changes. A newly added workflow is not evidence of a
passing run: inspect its actual status before merging.

## Build reproducibility

DataFusion 53.1.0, delta-rs 0.32.4 and the inspected Policast git revision are
pinned. The Rust builder remains 1.98.0, consistent with the working local image.
Transitive versions are not fully pinned until Cargo.lock is committed.
After a successful build, export the exact lockfile used by that image:

```bash
bash export-lockfile.sh
git add app/Cargo.lock
git commit -m 'Lock governed Delta demo dependencies'
```

The exporter refuses to overwrite an existing lockfile. Subsequent image builds
run Cargo with `--locked`. Rust unit tests and both binaries use the same build.
Debug builds and BuildKit caches remain enabled for iteration, with two parallel
Cargo jobs by default to reduce memory pressure. No claim of full reproducibility
is made while Cargo.lock is absent or mutable container tags remain.

## Local development services

Postgres is on 127.0.0.1:5432 (database/user/password: governance). MinIO API is on
127.0.0.1:9000; console on 127.0.0.1:9001 (minioadmin / minioadmin123). These are
publicly documented demo credentials, not production secrets. Never load real
sensitive data into this setup without replacing credentials and hardening it.
`AWS_S3_ALLOW_UNSAFE_RENAME=true` remains for the original single-writer local demo;
do not use it as a production multi-writer configuration.
