# Delta + DataFusion + Policast + Postgres + MinIO demo

Purpose: prove a lightweight SME governance path with no Spark, OPA, Trino, or Unity Catalog.

## Architecture

- **Postgres 18**: principals, dynamic attributes, Cedar policy source, policy bindings
- **MinIO**: Delta Lake table files and `_delta_log`
- **Rust demo**: Rust 1.98 + delta-rs 0.32.4 + DataFusion 53.1
- **Policast**: Cedar -> CEL, row filters, column masks, deny override

The Policast revision is pinned to `c6891d553fa1105546668c75b9a0d175bc54f70d`, whose workspace currently pins DataFusion 53.1 and deltalake 0.32.4.

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

Therefore policies may use arbitrary attributes without a Rust change, for example:

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

`resource.<field>` is resolved as a DataFusion table column. `principal.<field>` is resolved from the dynamic identity bag.

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

The shipped bindings are roughly:

```text
row_filter_region      -> role:analyst
row_filter_physician   -> role:physician
mask_ssn                -> *
mask_diagnosis          -> *
deny_legal_hold         -> *
```

Changing a binding does not require editing Cedar or rebuilding Rust.

### Fail-closed principal contract

Policast derives the set of `principal.<attribute>` fields referenced by the resolved policies. Before registering the Delta table, this gateway verifies that the current principal contains every required attribute.

For example, if a policy changes to:

```cedar
resource.department == principal.department
```

but the principal has no `department`, the query fails with `ACCESS_DENIED` before the governed table is exposed. This prevents a missing attribute from weakening a row filter.

## First run after the dynamic-schema update

The Postgres seed schema changed from fixed `region` columns to JSONB attributes and explicit bindings. If you ran an earlier revision, recreate the disposable demo volume once:

```bash
git pull origin feature/delta-policast-sme-demo
cd governance/delta-policast-sme-demo

docker compose down -v --remove-orphans
docker compose up -d postgres minio
docker compose run --rm minio-init
docker compose build governed-query
```

Do not use `down -v` on a production database whose data you need to preserve.

## Run the demo

```bash
bash demo.sh
```

Or manually:

```bash
docker compose run --rm governed-query admin
docker compose run --rm governed-query physician
docker compose run --rm governed-query analyst
```

Expected baseline:

| Principal | Rows | SSN | diagnosis |
|---|---|---|---|
| admin | all non-legal-hold rows | visible | visible |
| physician | only rows for Dr. Smith | visible | visible |
| analyst | only `us-east` rows | masked | masked |

`patient 1005` is on legal hold and should be absent for all three.

Expected resolved policy counts:

- `admin`: 3
- `physician`: 4
- `analyst`: 4

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

A Cedar policy may then reference `principal.branch`. The only requirement is that the governed table also has the resource column referenced by the rule.

## Change policy assignment at runtime

For example, bind the regional rule to one named principal instead of the whole analyst role:

```bash
docker compose exec postgres psql -U governance -d governance -c \
  "UPDATE governance.policy_bindings
   SET principal_selector='principal:analyst'
   WHERE binding_id='bind_region_analyst';"
```

Again, no Rust rebuild is required.

## Regression suite

The automated suite captures the behaviors proven manually during development:

1. admin broad access + legal-hold deny
2. physician own-patient row filter
3. analyst regional row filter + masks
4. unknown principal denied
5. malformed bound Cedar fails closed
6. runtime `region` change takes effect without rebuild
7. a brand-new `doctor_scope` attribute works after only DB/Cedar changes
8. removing that required attribute fails closed

Run:

```bash
bash test-governance.sh
```

Skip the image build when it is already current:

```bash
SKIP_BUILD=1 bash test-governance.sh
```

The test script restores the analyst attributes and regional policy after destructive tests.

## Build reproducibility

The Dockerfile automatically uses `cargo build --locked` when `app/Cargo.lock` exists. This environment cannot generate Cargo's lockfile, so generate it once locally and commit it:

```bash
docker run --rm \
  -v "$PWD/app:/app" \
  -w /app \
  rust:1.98.0-bookworm \
  cargo generate-lockfile

git add app/Cargo.lock
git commit -m "Lock Delta governance demo dependencies"
```

After that, Docker builds fail rather than silently changing transitive dependency versions.

For this functional POC the image still uses a debug Cargo build for fast iteration. Switch to `--release --locked` when the reference implementation is frozen.

## PostgreSQL 18 volume layout

PostgreSQL 18+ expects the persistent volume at `/var/lib/postgresql`; it creates a major-version-specific data directory beneath that path. The Compose file already uses this layout.

## Local endpoints

MinIO console: `http://localhost:9001`

- user: `minioadmin`
- password: `minioadmin123`

Postgres:

- host: `localhost:5432`
- db: `governance`
- user/password: `governance` / `governance`

## Important demo limitation

The Compose file sets `AWS_S3_ALLOW_UNSAFE_RENAME=true` to keep the MinIO test single-writer and dependency-free. Do **not** treat that as the final multi-writer production setting. Before production, switch to a commit-safe configuration appropriate to the object store and concurrency model.

## Reset

```bash
docker compose down -v
```
