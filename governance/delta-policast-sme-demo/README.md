# Delta + DataFusion + Policast + Postgres + MinIO demo

Purpose: prove a lightweight SME governance path with no Spark, OPA, Trino, or Unity Catalog.

## Architecture

- **Postgres 18**: principals + Cedar policy source (control plane)
- **MinIO**: Delta Lake table files and `_delta_log` (data plane)
- **Rust demo**: Rust 1.98 + delta-rs 0.32.4 + DataFusion 53.1 + Policast
- **Policast**: row filters, column masks, deny override

The Policast revision is pinned to `c6891d553fa1105546668c75b9a0d175bc54f70d`, whose workspace currently pins DataFusion 53.1 and deltalake 0.32.4.

### Policy resolution in this POC

Policast's DataFusion enforcement layer applies the policies present in the resolved manifest; it does not itself decide whether a role-scoped policy should be included. The full Policast resolver normally performs principal/binding selection before returning that manifest.

Because this POC intentionally skips the resolver sidecar, the Rust demo performs a minimal in-process resolve step after compiling Cedar from Postgres: policies with `@roles(...)` are kept only for matching roles, while unscoped policies (such as the sensitive-column masks and legal-hold deny rule) remain global.

This is sufficient for the POC. A production control plane should model policy bindings explicitly (role/group/principal + resource) rather than treating this mini-resolver as the final policy-store design.

## Run everything

```bash
bash demo.sh
```

Or manually:

```bash
docker compose up -d postgres minio
docker compose run --rm minio-init
docker compose build --pull governed-query

docker compose run --rm governed-query admin
docker compose run --rm governed-query physician
docker compose run --rm governed-query analyst
```

The Docker builder is pinned to `rust:1.98.0-bookworm`. This is intentionally newer than the minimum required by the current AWS SDK transitive dependencies pulled by delta-rs S3 support.

For this functional POC the container uses a **debug Cargo build** rather than `--release`, and Docker BuildKit caches the Cargo registry, git dependencies, and target directory. This keeps the edit/compile cycle much shorter while we stabilize the integration. Switch to a release build after the demo is passing end to end.

### PostgreSQL 18 volume layout

PostgreSQL 18+ expects the persistent volume to be mounted at `/var/lib/postgresql`; it creates a major-version-specific data directory beneath that path. If you previously started this demo with the old `/var/lib/postgresql/data` mount, remove the old demo volume once before restarting:

```bash
docker compose down -v --remove-orphans
docker compose up -d postgres minio
docker compose logs -f postgres
```

This is safe for this disposable demo, but do not use `down -v` against a production database whose data you need to preserve.

MinIO console: http://localhost:9001

- user: `minioadmin`
- password: `minioadmin123`

Postgres:

- host: `localhost:5432`
- db: `governance`
- user/password: `governance` / `governance`

## Expected governance

| Principal | Rows | SSN | diagnosis |
|---|---|---|---|
| admin | all non-legal-hold rows | visible | visible |
| physician | only rows for Dr. Smith | visible | visible |
| analyst | only `us-east` rows | masked | masked |

`patient 1005` is on legal hold and should be filtered for all three demo roles.

Expected policy-resolution counts with the shipped five policies:

- `admin`: 5 compiled, 3 resolved
- `physician`: 5 compiled, 4 resolved
- `analyst`: 5 compiled, 4 resolved

## Change a policy without rebuilding the Rust image

For example, change the analyst region principal:

```bash
docker compose exec postgres psql -U governance -d governance -c \
  "UPDATE governance.principals SET region='us-west' WHERE principal_key='analyst';"

docker compose run --rm governed-query analyst
```

Or edit the Cedar stored in `governance.policies`, then rerun the query container. Policies are fetched and compiled at runtime.

## Build reproducibility

This proof-of-concept currently does not commit the app `Cargo.lock`. After the first successful local build, commit `app/Cargo.lock` and switch the Docker build to `cargo build --release --locked` so future transitive dependency upgrades cannot unexpectedly change the required Rust version or behavior.

## Important demo limitation

The Compose file sets `AWS_S3_ALLOW_UNSAFE_RENAME=true` to keep the MinIO test single-writer and dependency-free. Do **not** treat that as the final multi-writer production setting. For production we should switch to a commit-safe configuration (for MinIO, evaluate conditional PUT support; for AWS S3, delta-rs documents a locking provider).

## Reset

```bash
docker compose down -v
```
