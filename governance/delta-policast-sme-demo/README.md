# Delta + DataFusion + Policast + Postgres + MinIO demo

Purpose: prove a lightweight SME governance path with no Spark, OPA, Trino, or Unity Catalog.

## Architecture

- **Postgres 18**: principals, dynamic attributes, Cedar policy source, policy bindings
- **MinIO**: Delta Lake table files and `_delta_log`
- **Rust demo**: Rust 1.98 + delta-rs 0.32.4 + DataFusion 53.1
- **Policast**: Cedar -> CEL, row filters, column masks, deny override

The Policast revision is pinned to `c6891d553fa1105546668c75b9a0d175bc54f70d`, whose workspace pins DataFusion 53.1 and deltalake 0.32.4.

## Dynamic governance model

The query service has no hard-coded `region` filter. `region` is only one demo attribute.

A principal has a stable envelope plus open-ended string attributes:

```text
governance.principals
  principal_key
  role
  display_name
  attributes JSONB
```

Example analyst attributes:

```json
{
  "region": "us-east",
  "department": "analytics",
  "company_id": "demo-co"
}
```

The service builds Policast `AttrIdentity` dynamically from that JSONB plus reserved system fields:

- `principal.role`
- `principal.principal_id`
- `principal.name`
- every string key in `attributes`

Therefore policies may use arbitrary string attributes without a Rust change, for example:

```cedar
when {
    resource.department == principal.department
};
```

or:

```cedar
when {
    resource.company_id == principal.company_id &&
    resource.branch == principal.branch
};
```

`resource.<field>` is resolved as a DataFusion table column. `principal.<field>` is resolved from the dynamic identity bag. The resource columns must exist and the expression must be supported by the pinned Policast translator; this is not support for arbitrary SQL or all Cedar expressions.

Current Policast principal attributes are string-valued. The gateway rejects non-string JSON attribute values rather than silently coercing them.

### Policy logic and policy assignment are separate

Cedar defines the rule. Postgres bindings define who receives the rule:

```text
governance.policies
  policy_key
  cedar
  enabled

governance.policy_bindings
  binding_id
  policy_key
  target
  principal_selector
  precedence
  enabled
```

Supported selectors in this POC:

```text
*                    global
role:analyst         role binding
principal:alice      one principal
```

The shipped bindings are:

```text
row_filter_region      -> role:analyst
row_filter_physician   -> role:physician
mask_ssn                -> *
mask_diagnosis          -> *
deny_legal_hold         -> *
```

Changing a binding does not require editing Cedar or rebuilding Rust. The current resolver selects all matching policies; `precedence` is stored metadata, not an implemented priority/override mechanism.

### Fail-closed principal contract

Policast derives the set of `principal.<attribute>` fields referenced by the resolved policies. Before registering the Delta table, this gateway verifies that the current principal contains every required attribute.

For example, if a policy references `principal.department` but the principal has no `department`, the query fails with `ACCESS_DENIED`. This check protects missing attributes; it is not a claim that every unsupported expression or possible query shape has been validated.

## Upgrading an existing demo database

A successful Rust build does not upgrade an existing Postgres volume. Docker's `/docker-entrypoint-initdb.d` scripts run only when initializing an empty database directory. `CREATE TABLE IF NOT EXISTS` also does not add columns to an existing table.

An earlier demo has a separate `region` column but no `attributes` column or `policy_bindings` table. Use the migration instead of deleting volumes or replaying `init.sql` (which would overwrite demo principals and policies).

From this demo directory, on `feature/delta-policast-sme-demo`:

```bash
git pull --ff-only origin feature/delta-policast-sme-demo

docker compose exec -T postgres \
  psql -X -v ON_ERROR_STOP=1 -U governance -d governance \
  < postgres/migrations/001_dynamic_governance.sql

docker compose exec -T postgres \
  psql -X -v ON_ERROR_STOP=1 -U governance -d governance \
  -c 'SELECT principal_key, role, attributes FROM governance.principals ORDER BY principal_key;'

docker compose run --rm governed-query admin
```

The migration runs in one transaction. It adds JSONB attributes, copies each existing non-null legacy region (including a prior `us-west` change), and creates the original five demo bindings if the bindings table does not exist. It keeps existing principals, Cedar text, policy enabled flags, and all MinIO/Delta data. Existing dynamic attributes and bindings are not reset. The legacy `region` column is retained but ignored by the dynamic application; use JSONB for future changes.

The migration records `001_dynamic_governance` in `governance.schema_migrations`. Reruns do not restore removed attributes or deleted/disabled bindings. It is scoped to the original five-policy demo and its standard role assignments, not arbitrary custom legacy Cedar. Review custom assignments before migration; unrecognized legacy policy keys cause an abort rather than guessed bindings.

No query-image rebuild is required solely to apply this database migration. Rebuild after pulling to include newer Rust diagnostics and tests:

```bash
docker compose build governed-query
```

### Lookup error meanings

- `ACCESS_DENIED: unknown principal ...`: the lookup succeeded but returned no principal.
- `CONTROL_PLANE_ERROR: query principal ...`: the database query failed; the underlying SQLx/database error is retained. A missing column is a schema problem, not an unknown user.

Both cases stop the request before Delta access. The service does not run schema-changing SQL automatically on the query path.

## Fresh setup and demo

For an empty database, the Compose init script creates the dynamic schema directly:

```bash
bash demo.sh
```

Or manually:

```bash
docker compose up -d postgres minio
docker compose run --rm minio-init
docker compose build governed-query

docker compose run --rm governed-query admin
docker compose run --rm governed-query physician
docker compose run --rm governed-query analyst
```

Expected baseline with the default seed attributes:

| Principal | Rows | SSN | diagnosis |
|---|---|---|---|
| admin | all non-legal-hold rows | visible | visible |
| physician | only rows for Dr. Smith | visible | visible |
| analyst | only `us-east` rows | masked | masked |

Patient `1005` is on legal hold and should be absent for all three. An upgraded database retains its current region, so an analyst previously changed to `us-west` should still see `1002`, not the east-region rows.

Expected resolved policy counts: admin 3, physician 4, analyst 4.

## Change identity attributes at runtime

No image rebuild is required.

```bash
docker compose exec postgres psql -U governance -d governance -c \
  "UPDATE governance.principals
   SET attributes = jsonb_set(attributes, '{region}', '\"us-west\"'::jsonb, true)
   WHERE principal_key='analyst';"

docker compose run --rm governed-query analyst
```

The analyst should now see only patient `1002`; patient `1005` is also `us-west` but remains excluded by the legal-hold deny rule.

Add a brand-new attribute without touching Rust:

```bash
docker compose exec postgres psql -U governance -d governance -c \
  "UPDATE governance.principals
   SET attributes = attributes || '{\"branch\":\"lahore\"}'::jsonb
   WHERE principal_key='analyst';"
```

A supported Cedar expression may then reference `principal.branch`. The resource column used by the rule must exist on the governed table.

## Change policy assignment at runtime

For example, bind the regional rule to one named principal instead of the whole analyst role:

```bash
docker compose exec postgres psql -U governance -d governance -c \
  "UPDATE governance.policy_bindings
   SET principal_selector='principal:analyst'
   WHERE binding_id='bind_region_analyst';"
```

Again, no Rust rebuild is required.

## Tests

### Rust unit tests

The Docker build runs `cargo test` before `cargo build`. The unit tests cover dynamic attributes, reserved-field protection, principal contracts, selector construction, and principal lookup error handling. Tests added in `principal_lookup.rs` check a found principal, an absent principal, a column error, and a connection-pool error. Database failures must not be mislabeled as unknown principals.

Unit tests alone do not validate an existing database's schema or the full Delta/MinIO path.

### Schema migration regression tests

With the demo Postgres running:

```bash
bash test-migration.sh
```

This creates a uniquely named scratch database, tests the legacy-to-dynamic upgrade, rerun behavior after binding deletion/disablement, and preservation of an already-dynamic schema. The scratch database is removed on exit. It does not reset the normal `governance` database or touch MinIO. Creating the scratch database requires the demo database user's `CREATEDB` privilege.

### Governance end-to-end tests

The automated suite checks:

1. admin broad access + legal-hold deny
2. physician own-patient row filter
3. analyst regional row filter + masks
4. unknown principal denied
5. malformed bound Cedar fails closed
6. runtime `region` change without rebuild
7. a new `doctor_scope` attribute after DB/Cedar-only changes
8. missing required dynamic attribute fails closed

```bash
bash test-governance.sh
```

Skip the image build when it is already current:

```bash
SKIP_BUILD=1 bash test-governance.sh
```

This suite temporarily changes the analyst attributes and regional policy and attempts to restore them on exit. Use it on demo data, not a live customer's governance configuration. Schema migrations must have been applied first.

## Build reproducibility

The Dockerfile uses `cargo test --locked` and `cargo build --locked` when `app/Cargo.lock` exists. Generate and commit a lockfile to freeze dependency resolution:

```bash
docker run --rm \
  -v "$PWD/app:/app" \
  -w /app \
  rust:1.98.0-bookworm \
  cargo generate-lockfile

git add app/Cargo.lock
git commit -m "Lock Delta governance demo dependencies"
```

Without a committed lockfile, dependency resolution is not frozen. The functional POC uses a debug Cargo build; use `--release --locked` for performance measurements after validation.

## PostgreSQL 18 volume layout

PostgreSQL 18+ expects the persistent volume at `/var/lib/postgresql`; it creates a major-version-specific data directory beneath that path. The Compose file uses this layout. Moving an existing cluster between major versions is separate from this application-schema migration.

## Local endpoints

MinIO console: `http://localhost:9001`

- user: `minioadmin`
- password: `minioadmin123`

Postgres:

- host: `localhost:5432`
- db: `governance`
- user/password: `governance` / `governance`

## Important demo limitations

The Compose file uses `AWS_S3_ALLOW_UNSAFE_RENAME=true` for a single-writer local MinIO demo. It is not the final production multi-writer configuration. The demo also selects a principal via a CLI argument rather than authenticating a remote user; do not expose it as a production authorization gateway.

## Destructive reset (disposable data only)

The following deletes both the Postgres and MinIO demo volumes, including policies and Delta data. It is not needed for the dynamic-schema migration:

```bash
docker compose down -v
```
