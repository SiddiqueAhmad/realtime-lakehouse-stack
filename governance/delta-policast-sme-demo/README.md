# Delta + DataFusion + Policast + Postgres + MinIO demo

Purpose: prove a lightweight SME governance path with no Spark, OPA, Trino, or Unity Catalog.

## Architecture

- **Postgres 18**: principals + Cedar policy source (control plane)
- **MinIO**: Delta Lake table files and `_delta_log` (data plane)
- **Rust demo**: delta-rs 0.32.4 + DataFusion 53.1 + Policast
- **Policast**: row filters, column masks, deny override

The Policast revision is pinned to `c6891d553fa1105546668c75b9a0d175bc54f70d`, whose workspace currently pins DataFusion 53.1 and deltalake 0.32.4.

## Run everything

```bash
./demo.sh
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

## Change a policy without rebuilding the Rust image

For example, change the analyst region principal:

```bash
docker compose exec postgres psql -U governance -d governance -c \
  "UPDATE governance.principals SET region='us-west' WHERE principal_key='analyst';"

docker compose run --rm governed-query analyst
```

Or edit the Cedar stored in `governance.policies`, then rerun the query container. Policies are fetched and compiled at runtime.

## Important demo limitation

The Compose file sets `AWS_S3_ALLOW_UNSAFE_RENAME=true` to keep the MinIO test single-writer and dependency-free. Do **not** treat that as the final multi-writer production setting. For production we should switch to a commit-safe configuration (for MinIO, evaluate conditional PUT support; for AWS S3, delta-rs documents a locking provider).

## Reset

```bash
docker compose down -v
```
