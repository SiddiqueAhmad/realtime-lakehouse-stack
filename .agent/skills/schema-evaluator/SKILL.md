---
name: Schema Evaluator
description: Evaluates Postgres schema migrations for compatibility with Debezium-Iceberg schema evolution and generates migration scripts for downstream services
---

# Schema Evaluator Skill

This skill analyzes Postgres schema migrations and assesses their compatibility with Debezium-Iceberg's automatic schema evolution capabilities. It identifies which changes can be handled automatically and which require manual intervention, then generates ready-to-use migration scripts for downstream services (Iceberg tables and dbt models).

## Overview

The Debezium-Iceberg connector has built-in schema evolution support, but with limitations. This skill helps you:

1. **Assess migrations** before applying them to Postgres
2. **Identify risk levels**: Automatic ✅ / Manual ⚠️ / Risky 🚨
3. **Generate migration scripts** for downstream services (Iceberg, dbt)
4. **Prevent data pipeline failures** from incompatible schema changes

## Explicit Non-Goals

This skill **evaluates** and **generates scripts** but does NOT:

❌ **Execute migrations** - You must apply migrations manually or via your CI/CD pipeline  
❌ **Connect to databases** - No database connections are made; analysis is SQL-text-based  
❌ **Run backfills** - Backfill SQL is generated but not executed  
❌ **Modify Debezium configuration** - Assumes `allow-field-addition=true` is already set  
❌ **Introspect live schemas** - Cannot compare against actual database state (future enhancement)  
❌ **Handle DDL rollbacks** - Migration rollback must be planned separately  
❌ **Version migrations automatically** - You control the numbering and git workflow  

The skill's responsibility ends at generating SQL/guidance. All execution is your responsibility.

## How Debezium-Iceberg Handles Schema Changes

### Configuration
The key configuration is `debezium.sink.iceberg.allow-field-addition` in `application.properties`:
- `true` - Enables automatic schema evolution (recommended)
- `false` - Requires manual schema changes

### Automatic Handling (when `allow-field-addition=true`)

| Change Type | Behavior | Status |
|-------------|----------|--------|
| Add new column | ✅ Automatically added to Iceberg table | SAFE |
| Safe type expansion | ✅ Auto-expanded (e.g., int→long, int→double) | SAFE |
| Remove column | ⚠️ Column kept in Iceberg, new rows → NULL | CAUTION |

### Requires Manual Intervention

| Change Type | Issue | Status |
|-------------|-------|--------|
| Incompatible type change | 🚨 e.g., long→timestamp, float→int | MANUAL |
| Column rename | ⚠️ Treated as drop + add (data in old column) | MANUAL |
| Precision/scale reduction | 🚨 e.g., decimal(10,2)→decimal(8,2) | MANUAL |

## Schema Change Classification Rules

### SAFE - Automatic Handling
Changes that Debezium-Iceberg handles automatically without data loss:

**Adding Columns:**
```sql
ALTER TABLE customers ADD COLUMN phone VARCHAR(20);
ALTER TABLE products ADD COLUMN category_id INTEGER;
```

**Safe Type Expansions:**
```sql
-- Integer expansions
ALTER TABLE products ALTER COLUMN id TYPE BIGINT;  -- int→bigint ✅
-- Numeric expansions  
ALTER TABLE orders ALTER COLUMN price TYPE DOUBLE PRECISION;  -- int→double ✅
-- String length increases
ALTER TABLE customers ALTER COLUMN name TYPE VARCHAR(500);  -- varchar(255)→varchar(500) ✅
```

### CAUTION - Review Recommended
Changes that work but may have unintended consequences:

**Removing Columns:**
```sql
ALTER TABLE products DROP COLUMN description;
-- ⚠️ Column remains in Iceberg with NULLs for new records
-- ⚠️ Historical data still accessible
```

**Nullable Changes:**
```sql
ALTER TABLE customers ALTER COLUMN email DROP NOT NULL;
-- ⚠️ Iceberg schema doesn't enforce constraints
```

## Configurable Risk Policy

The evaluator's exit code behavior is configurable for CI/CD integration:

### Default Risk Policy

By default:
- 🚨 **MANUAL** changes → **FAIL** (exit code 1)
- ⚠️  **CAUTION** changes → **PASS** with warning (exit code 0)
- ✅ **SAFE** changes → **PASS** silently (exit code 0)

### Environment Variable Configuration

```bash
# Configure fail-on policy
export SCHEMA_EVALUATOR_FAIL_ON=MANUAL  # Default - fail only on manual migrations
export SCHEMA_EVALUATOR_FAIL_ON=CAUTION  # Stricter - fail on caution or manual
export SCHEMA_EVALUATOR_FAIL_ON=NONE     # Permissive - never fail, only warn
```

### Multi-Statement Migration  Handling

When a migration file contains **both** SAFE and MANUAL changes:
- **Overall status** = MANUAL (most restrictive wins)
- **Exit code** = Based on SCHEMA_EVALUATOR_FAIL_ON policy
- **Generated scripts** = Only for MANUAL statements

**Example:**
```sql
-- This migration has mixed changes
ALTER TABLE customers ADD COLUMN email VARCHAR(255);  -- SAFE
ALTER TABLE products RENAME COLUMN weight TO product_weight;  -- MANUAL
```

Result: Overall status is MANUAL, scripts generated only for the column rename.

### Using in CI/CD

**GitHub Actions Example:**
```yaml
name: Validate Migrations
on: [pull_request]
jobs:
  check-schema:
    runs-on: ubuntu-latest
    env:
      SCHEMA_EVALUATOR_FAIL_ON: MANUAL  # Block manual migrations in CI
    steps:
      - uses: actions/checkout@v3
      - name: Evaluate Migrations
        run: ./scripts/evaluate-migrations.sh
```

**Allow Manual with Approval:**
```yaml
- name: Evaluate Migrations
  id: eval
  continue-on-error: true
  run: ./scripts/evaluate-migrations.sh

- name: Request Manual Approval
  if: steps.eval.outcome == 'failure'
  uses: trstringer/manual-approval@v1
  with:
    approvers: schema-team
    minimum-approvals: 2
```

## Constraint Handling

Postgres constraints (CHECK, FOREIGN KEY, UNIQUE, NOT NULL) are enforced in your source database but **NOT replicated or enforced in Iceberg**. Understanding this is critical for data quality.

### Constraint Types and Behavior

| Constraint Type | Postgres Behavior | Iceberg Behavior | Recommendation |
|----------------|-------------------|------------------|----------------|
| **NOT NULL** | Enforced on INSERT/UPDATE | Not enforced | Application-level validation required |
| **CHECK** | Validates data rules | Not replicated | Move validation to application layer |
| **FOREIGN KEY** | Enforces referential integrity | Not replicated | Handle joins carefully in dbt/queries |
| **UNIQUE** | Prevents duplicates | Not enforced | Deduplicate in dbt transformations |
| **PRIMARY KEY** | Enforced + indexed | Not enforced (just metadata) | Use for merge keys, not uniqueness guarantee |

### What This Means for Your Pipeline

**Constraints are filtered out before CDC:**
```sql
-- In Postgres (enforced)
ALTER TABLE customers ADD CONSTRAINT check_age CHECK (age >= 18);
```

Debezium captures data **after** constraint validation. The constraint itself doesn't flow to Iceberg.

**Impact:**
- ✅ Only valid data reaches Iceberg (Postgres blocks invalid inserts)
- ⚠️  If you query Iceberg directly (bypassing Postgres), no validation occurs
- ⚠️  Historical data might violate constraints if they were added later

### Recommendations

1. **Keep constraints in Postgres** - They protect your source data
2. **Don't rely on them downstream** - Iceberg doesn't enforce them
3. **Add dbt tests for data quality**:
   ```yaml
   models:
     - name: customers
       columns:
         - name: age
           tests:
             - not_null
             - dbt_utils.accepted_range:
                 min_value: 18
   ```
4. **Document constraint changes** - They affect application behavior but not Iceberg schema

### Safe Constraint Operations

These are classified as **CAUTION** because they work but have no effect on Iceberg:

```sql
-- Adding constraints
ALTER TABLE orders ADD CONSTRAINT check_positive_quantity CHECK (quantity > 0);  -- ⚠️ CAUTION
ALTER TABLE customers ADD CONSTRAINT unique_email UNIQUE (email);  -- ⚠️ CAUTION

-- Dropping constraints  
ALTER TABLE orders DROP CONSTRAINT check_positive_quantity;  -- ⚠️ CAUTION
```

**Why CAUTION?**
- Postgres behavior changes (more/less restrictive)
- Iceberg data remains unaffected
- Might confuse developers expecting downstream enforcement

## Data Backfill Strategy (Lazy vs. Eager)

After a manual migration (e.g., column rename), you need to decide how to handle existing data. The evaluator generates scripts for both strategies—you choose which to execute.

### Decision Matrix

| Strategy | Description | Best For | Pros | Cons |
|----------|-------------|----------|------|------|
| **Lazy (View-Layer)** | Rename old column in Iceberg. Use `COALESCE(new, old)` in dbt. Do NOT UPDATE raw data. | Large Tables (>100GB) | Instant; Zero cost; No file rewrites | Raw data has two columns for same concept |
| **Eager (Write-Layer)** | Rename old column. Run `UPDATE table SET new = old`. Drop old column. | Small Tables (<1GB) | Clean raw data; Simple downstream queries | Expensive; Slow; Rewrites files (Time Travel impact) |

### Lazy Migration (Recommended for Large Tables)

**Iceberg Migration:**
```sql
-- Step 1: Rename old column (instant, metadata-only)
ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  RENAME COLUMN weight TO weight_legacy;

-- Step 2: Restart Debezium (new column 'product_weight' created automatically)
-- Step 3: Done! No data backfill needed.
```

**dbt Layer (Silver/Gold):**
```sql
-- Handle both old and new data seamlessly
SELECT
  id,
  name,
  COALESCE(product_weight, weight_legacy) AS product_weight,
  ...
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

**Advantages:**
- ✅ Instant (metadata-only operation)
- ✅ No Iceberg file rewrites
- ✅ Preserves Time Travel history
- ✅ Zero downtime

**Tradeoffs:**
- ❌ Raw Iceberg table has duplicate columns (`weight_legacy` + `product_weight`)
- ❌ All downstream queries must use `COALESCE`
- ❌ Storage: old column data persists (negligible for most cases)

### Eager Migration (For Small Tables)

**Iceberg Migration:**
```sql
-- Step 1: Rename old column
ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  RENAME COLUMN weight TO weight_legacy;

-- Step 2: Restart Debezium (new column created)

-- Step 3: Backfill data (EXPENSIVE - rewrites all files!)
UPDATE iceberg.icebergdata.debeziumcdc_products
  SET product_weight = weight_legacy
  WHERE product_weight IS NULL;

-- Step 4: (Optional) Drop legacy column after verification
-- ALTER TABLE iceberg.icebergdata.debeziumcdc_products DROP COLUMN weight_legacy;
```

**dbt Layer:**
```sql
-- Simple queries (no COALESCE needed after backfill)
SELECT
  id,
  name,
  product_weight,  -- Clean!
  ...
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

**Advantages:**
- ✅ Clean raw data (single source of truth)
- ✅ Simple downstream queries
- ✅ Can drop legacy column later

**Tradeoffs:**
- ❌ Expensive (full table rewrite)
- ❌ Slow (hours for large tables)
- ❌ Time Travel: creates new snapshots, old snapshots reference deleted columns
- ❌ Requires downtime or careful coordination

### Backfill Responsibility

The evaluator:
- ✅ **Generates** migration SQL scaffolding
- ✅ **Provides** both Lazy and Eager options
- ✅ **Recommends** strategy based on best practices
- ❌ **Does NOT execute** backfills

**You are responsible for:**
1. Choosing Lazy vs. Eager based on table size and team preferences
2. Executing the generated SQL in your Spark/Trino environment
3. Ensuring backfills are **idempotent** (safe to re-run)
4. Chunking large backfills to avoid timeouts

### Idempotent Backfill Pattern

All generated backfills follow this pattern:

```sql
-- Idempotent: Only updates rows where new column is NULL
UPDATE iceberg.icebergdata.debeziumcdc_products
  SET product_weight = weight_legacy
  WHERE product_weight IS NULL;  -- Safe to re-run!
```

### Chunked Backfill (For Very Large Tables)

For tables >10M rows, run backfills in chunks:

```sql
-- Chunk by ID range
UPDATE iceberg.icebergdata.debeziumcdc_products
  SET product_weight = weight_legacy
  WHERE product_weight IS NULL
    AND id BETWEEN 0 AND 1000000;

-- Repeat with next range...
-- WHERE id BETWEEN 1000001 AND 2000000;
```

**Our Recommendation:**
- Default to **Lazy** for tables >1GB or >1M rows
- Use **Eager** only for small reference tables (<100MB)
- Document your choice in the migration file comments

### MANUAL - Intervention Required

Changes that will cause Debezium to fail or lose data:
```sql
-- Type narrowing
ALTER TABLE orders ALTER COLUMN quantity TYPE SMALLINT;  -- int→smallint 🚨
-- Semantic changes
ALTER TABLE orders ALTER COLUMN order_date TYPE TIMESTAMP;  -- date→timestamp 🚨
-- Precision reduction
ALTER TABLE products ALTER COLUMN price TYPE DECIMAL(8,2);  -- decimal(10,2)→decimal(8,2) 🚨
```

**Column Renames:**
```sql
ALTER TABLE products RENAME COLUMN weight TO product_weight;
-- 🚨 Debezium treats as: DROP weight + ADD product_weight
-- 🚨 Data in 'weight' column lost for new records
```

## Using the Schema Evaluator

### 1. Create a Migration File

Place your SQL migration in the `migrations/` directory:

```bash
# migrations/001_add_customer_phone.sql
ALTER TABLE inventory.customers ADD COLUMN phone VARCHAR(20);
ALTER TABLE inventory.customers ADD COLUMN phone_verified BOOLEAN DEFAULT FALSE;
```

### 2. Run the Evaluation

```bash
./scripts/evaluate-migrations.sh
```

### 3. Review the Assessment

The script will output:

```
📋 Evaluating migration: 001_add_customer_phone.sql
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✅ SAFE: ADD COLUMN phone VARCHAR(20)
     → Will be automatically added to Iceberg table
  
  ✅ SAFE: ADD COLUMN phone_verified BOOLEAN DEFAULT FALSE
     → Will be automatically added to Iceberg table

📊 Summary: 2 changes detected
  ✅ Safe (automatic): 2
  ⚠️  Caution (review): 0
  🚨 Manual (intervention): 0

✅ Migration can be applied safely
```

## The "Ghost Column" Cleanup (Iceberg Maintenance)

After running a Lazy Mi migration, your Iceberg table has "ghost columns" (e.g., `weight_legacy`) that are no longer used but still consume storage and appear in schemas.

### When to Clean Up Ghost Columns

**Keep ghost columns if:**
- ⏱️ Migration was recent (< 30 days) - rollback might be needed
- 📊 Analytics teams query historical snapshots via Time Travel
- 💾 Storage cost is negligible

**Drop ghost columns if:**
- ✅ Migration is stable (> 90 days, no issues)
- ✅ All downstream queries use `COALESCE` or new column exclusively
- ✅ Time Travel history beyond retention period
- ✅ Table compaction/optimization planned anyway

### Ghost Column Cleanup Script

The generator produces cleanup SQL (commented out by default):

```sql
-- ═══════════════════════════════════════════════════════════════
-- GHOST COLUMN CLEANUP (Run after 90+ days)
-- ═══════════════════════════════════════════════════════════════

-- ⚠️  WARNING: This permanently deletes the column and its data!
-- ⚠️  Historical Time Travel  queries will fail if they reference this column
-- ⚠️  Ensure all downstream systems use the new column first!

-- DROP COLUMN is a metadata operation (fast) but:
-- - Makes column inaccessible
-- - Orphans data files (requires REWRITE DATA FILES or VACUUM to reclaim storage)

ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  DROP COLUMN weight_legacy;

-- To actually reclaim storage, run compaction:
-- ALTER TABLE iceberg.icebergdata.debeziumcdc_products
--   REWRITE DATA FILES;  -- Expensive! Rewrites all files to remove column data

-- Alternative: Wait for scheduled table optimization/compaction
```

### Cleanup Checklist

Before dropping a ghost column:

- [ ] Verify column is unused in dbt models (search codebase for `weight_legacy`)
- [ ] Check Metabase/BI dashboards don't reference it
- [ ] Confirm no Time Travel queries need it (`SELECT ... FOR SYSTEM_TIME AS OF`)
- [ ] Document the cleanup in migration notes
- [ ] Run in staging first
- [ ] Plan for storage reclamation (compaction) if table is large

### Storage Reclamation Strategy

**Option 1: Immediate Reclamation (Expensive)**
```sql
ALTER TABLE iceberg.icebergdata.debeziumcdc_products DROP COLUMN weight_legacy;
ALTER TABLE iceberg.icebergdata.debeziumcdc_products REWRITE DATA FILES;
```
- Rewrites all files immediately
- Costly for large tables

**Option 2: Lazy Reclamation (Recommended)**
```sql
ALTER TABLE iceberg.icebergdata.debeziumcdc_products DROP COLUMN weight_legacy;
-- Wait for next scheduled compaction/optimization
-- Or trigger during maintenance window
```
- Column is immediately inaccessible (metadata update)
- Data files rewritten during next table optimization

## The "Sequence of Events" Guardrail

Manual migrations require precise sequencing. The evaluator generates a step-by-step checklist to prevent errors.

### Migration Sequence for Column Rename/Type Change

#### Phase 1: Preparation
```
[  ] 1. Evaluate migration: ./scripts/evaluate-migrations.sh
[  ] 2. Generate Iceberg migration: generate_iceberg_migration.py
[  ] 3. Generate dbt updates: generate_dbt_migration.py
[  ] 4. Review generated scripts
[  ] 5. Test in staging environment
[  ] 6. Notify stakeholders (BI team, data consumers)
```

#### Phase 2: Execution
```
[  ] 7. Stop Debezium server
          docker-compose stop debezium  (or equivalent)

[  ] 8. Apply Iceberg migration
          Run generated iceberg_migration.sql in Trino/Spark

[  ] 9. Verify Iceberg table schema
          DESCRIBE iceberg.icebergdata.debeziumcdc_products;

[  ] 10. Apply Postgres migration
           psql -f migrations/002_rename_weight.sql

[  ] 11. Restart Debezium server
           docker-compose start debezium

[  ] 12. Verify Debezium is healthy
           Check logs for errors, verify offset commits
```

#### Phase 3: Validation
```
[  ] 13. Check new data flow
           INSERT test record in Postgres
           Verify it appears in Iceberg with new column populated

[  ] 14. Update dbt models
           Apply generated dbt SQL changes

[  ] 15. Run dbt
           dbt run --select affected_models

[  ] 16. Test dbt models
           dbt test --select affected_models

[  ] 17. (Optional) Run backfill
           If using Eager strategy, execute UPDATE statements
```

#### Phase 4: Cleanup (After 90 Days)
```
[  ] 18. Drop ghost column (optional)
           ALTER TABLE ... DROP COLUMN weight_legacy;

[  ] 19. Optimize table (optional)
           REWRITE DATA FILES or wait for scheduled compaction
```

### What Happens If You Skip Steps?

| Skipped Step | Consequence |
|-------------|-------------|
| Stop Debezium first | Debezium fails with "Cannot change column type" error |
| Apply Iceberg migration first | Data flows to wrong column, data loss |
| Restart Debezium | New data never flows, pipeline stuck |
| Update dbt models | Queries fail with "column does not exist" |
| Verify new data flow | Silent data quality issues go unnoticed |

### Auto-Generated Checklists

The migration generators include this checklist in comments:

```sql
-- ═══════════════════════════════════════════════════════════════
-- MIGRATION CHECKLIST
-- ═══════════════════════════════════════════════════════════════
-- [ ] Stop Debezium
-- [ ] Apply this Iceberg migration
-- [ ] Verify Iceberg table schema
-- [ ] Apply Postgres migration file:///path/to/002_rename.sql
-- [ ] Restart Debezium
-- [ ] Verify new data flows correctly
-- [ ] Update dbt models with generated SQL
-- [ ] Run dbt test
-- [ ] (Optional) Execute backfill if using Eager strategy
```

Copy this checklist to your migration PR description or run it as a runbook.

### 4. For Manual Migrations - Generate Helper Scripts

When manual intervention is needed:

```bash
# Generate Iceberg migration SQL
python .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py \
  migrations/002_rename_weight_column.sql \
  --output iceberg_migration_002.sql

# Generate dbt model updates
python .agent/skills/schema-evaluator/scripts/generate_dbt_migration.py \
  migrations/002_rename_weight_column.sql \
  --output dbt_migration_002.sql
```

## Generated Migration Scripts

### For Iceberg Tables

When you have an incompatible type change or column rename, the script generates Spark SQL:

**Example: Column Rename**
```sql
-- Generated Iceberg migration for: RENAME COLUMN weight TO product_weight
-- Strategy: Rename old column to preserve data, new column will be auto-created

-- Execute this in your Spark environment (Trino, Spark SQL, etc.)
ALTER TABLE iceberg.icebergdata.debeziumcdc_products 
  RENAME COLUMN weight TO weight_legacy;

-- After running Debezium, the new 'product_weight' column will be created automatically
-- You can then migrate data:
-- UPDATE iceberg.icebergdata.debeziumcdc_products 
--   SET product_weight = weight_legacy 
--   WHERE product_weight IS NULL;
```

**Example: Type Change**
```sql
-- Generated Iceberg migration for: ALTER COLUMN order_date TYPE TIMESTAMP
-- Strategy: Rename column, let Debezium create new one with correct type

ALTER TABLE iceberg.icebergdata.debeziumcdc_orders 
  RENAME COLUMN order_date TO order_date_legacy;

-- After Debezium creates the new column, migrate the data:
-- UPDATE iceberg.icebergdata.debeziumcdc_orders
--   SET order_date = CAST(order_date_legacy AS TIMESTAMP)
--   WHERE order_date IS NULL;
```

### For dbt Models

When upstream schema changes, update your dbt models:

**Example: Column Rename in dbt**
```sql
-- models/silver/enriched_orders.sql
-- Updated to handle column rename: weight → product_weight

SELECT
    o.order_number,
    o.order_date,
    p.name as product_name,
    -- Use new column name, fallback to legacy for historical data
    COALESCE(p.product_weight, p.weight_legacy) as product_weight,
    o.quantity
FROM {{ source('iceberg', 'debeziumcdc_orders') }} o
LEFT JOIN {{ source('iceberg', 'debeziumcdc_products') }} p 
    ON o.product_id = p.id
```

**Schema YAML Update:**
```yaml
# models/schema.yml
models:
  - name: enriched_orders
    columns:
      - name: product_weight
        description: "Product weight (migrated from weight column)"
        tests:
          - not_null
```

## Machine-Readable Output

For CI/CD integration, the evaluator supports JSON output for programmatic consumption.

### Usage

```bash
# Human-readable output (default)
python analyze_migration.py migrations/001_add_column.sql

# Machine-readable JSON output
python analyze_migration.py migrations/001_add_column.sql --json
```

### JSON Output Schema

```json
{
  "migration_file": "migrations/002_rename_weight.sql",
  "overall_status": "manual",
  "timestamp": "2026-01-26T09:47:00Z",
  "changes": [
    {
      "change_type": "rename_column",
      "table_name": "inventory.products",
      "column_name": "weight → product_weight",
      "status": "manual",
      "explanation": "Debezium treats column rename as DROP + ADD...",
      "sql_statement": "ALTER TABLE inventory.products RENAME COLUMN weight TO product_weight;",
      "line_number": 5
    }
  ],
  "summary": {
    "total_changes": 1,
    "safe": 0,
    "caution": 0,
    "manual": 1
  },
  "requires_intervention": true,
  "generated_scripts": {
    "iceberg_migration": "iceberg_migration_002.sql",
    "dbt_migration": "dbt_migration_002.sql"
  },
  "recommended_action": "Generate migration scripts and follow manual migration workflow"
}
```

### CI/CD Integration Example

**GitHub Actions with JSON Parsing:**
```yaml
- name: Evaluate Migrations
  id: eval
  run: |
    OUTPUT=$(python .agent/skills/schema-evaluator/scripts/analyze_migration.py \
      migrations/*.sql --json)
    echo "result=$OUTPUT" >> $GITHUB_OUTPUT

- name: Check for Manual Migrations
  run: |
    STATUS=$(echo '${{ steps.eval.outputs.result }}' | jq -r '.overall_status')
    if [ "$STATUS" == "manual" ]; then
      echo "::error::Manual migration detected. Generate scripts before merging."
      exit 1
    fi

- name: Post PR Comment  
  if: failure()
  uses: actions/github-script@v6
  with:
    script: |
      const output = JSON.parse('${{ steps.eval.outputs.result }}');
      const comment = `## 🚨 Schema Migration Requires Manual Intervention
      
      **Changes detected:**
      ${output.changes.map(c => `- ${c.change_type}: ${c.table_name}.${c.column_name} (${c.status})`).join('\n')}
      
      **Next steps:**
      1. Generate migration scripts:
         \`\`\`bash
         python .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py ${output.migration_file}
         python .agent/skills/schema-evaluator/scripts/generate_dbt_migration.py ${output.migration_file}
         \`\`\`
      2. Review generated scripts
      3. Follow manual migration workflow`;
      
      github.rest.issues.createComment({
        issue_number: context.issue.number,
        owner: context.repo.owner,
        repo: context.repo.repo,
        body: comment
      });
```

**Using jq to Extract Fields:**
```bash
# Get overall status
python analyze_migration.py migrations/001.sql --json | jq -r '.overall_status'

# Count manual changes
python analyze_migration.py migrations/001.sql --json | jq '.summary.manual'

# Extract all table names with manual changes
python analyze_migration.py migrations/001.sql --json | \
  jq -r '.changes[] | select(.status=="manual") | .table_name' | sort -u
```

**Slack Notification Integration:**
```bash
#!/bin/bash
OUTPUT=$(python analyze_migration.py migrations/latest.sql --json)
STATUS=$(echo "$OUTPUT" | jq -r '.overall_status')

if [ "$STATUS" == "manual" ]; then
  TABLES=$(echo "$OUTPUT" | jq -r '.changes[].table_name' | sort -u | tr '\n' ', ')
  
  curl -X POST $SLACK_WEBHOOK_URL \
    -H 'Content-Type: application/json' \
    -d "{
      \"text\": \"🚨 Manual schema migration required\",
      \"blocks\": [{
        \"type\": \"section\",
        \"text\": {
          \"type\": \"mrkdwn\",
          \"text\": \"*Tables affected:* $TABLES\n*Action needed:* Generate migration scripts\"
        }
      }]
    }"
fi
```

## Best Practices

### 1. Always Test in Development First
```bash
# Run evaluation on staging/dev migrations
./scripts/evaluate-migrations.sh --env dev
```

### 2. Version Control All Migrations
- ✅ Commit migrations to git before applying
- ✅ Use sequential numbering (001, 002, 003...)
- ✅ Include descriptive names

### 3. Handle Manual Migrations Carefully
1. Stop Debezium server
2. Apply Iceberg migration (rename column)
3. Apply Postgres migration
4. Restart Debezium
5. Verify new data flows correctly
6. Update dbt models
7. Backfill historical data if needed

### 4. Document Breaking Changes
Add comments to your migration files:
```sql
-- Migration: 002_rename_weight_column.sql
-- Type: MANUAL - Column rename
-- Downstream Impact: Requires Iceberg table update and dbt model changes
-- Generated scripts: iceberg_migration_002.sql, dbt_migration_002.sql

ALTER TABLE inventory.products RENAME COLUMN weight TO product_weight;
```

## Troubleshooting

### Debezium Fails with "Cannot change column type"

**Error:**
```
java.lang.IllegalArgumentException: Cannot change column type: order_date: date -> timestamp
```

**Solution:**
1. Run the evaluator to get the migration script
2. Stop Debezium
3. Apply the Iceberg migration (rename old column)
4. Restart Debezium (new column will be created)
5. Backfill data from old to new column

### dbt Models Fail After Schema Change

**Error:**
```
column "weight" does not exist
```

**Solution:**
1. Run `generate_dbt_migration.py` to get updated model SQL
2. Update the dbt model with `COALESCE(new_column, old_column)`
3. Run `dbt run --full-refresh` if needed

## Advanced Usage

### Custom Type Mapping Rules

Edit `.agent/skills/schema-evaluator/scripts/schema_rules.py` to add custom rules:

```python
# Example: Mark specific type changes as safe for your use case
CUSTOM_SAFE_CONVERSIONS = {
    ('date', 'timestamp'): 'Safe for our use case - we always convert dates',
}
```

### Integration with CI/CD

Add to your GitHub Actions workflow:

```yaml
- name: Evaluate Schema Migrations
  run: |
    ./scripts/evaluate-migrations.sh
    if [ $? -ne 0 ]; then
      echo "❌ Schema migration requires manual intervention"
      exit 1
    fi
```

## References

- [Debezium Iceberg Schema Evolution](https://memiiso.github.io/debezium-server-iceberg/iceberg/#automatic-schema-change-handling)
- [Debezium Iceberg Migration Guide](https://memiiso.github.io/debezium-server-iceberg/migration/)
- [Apache Iceberg Schema Evolution](https://iceberg.apache.org/docs/latest/evolution/)
