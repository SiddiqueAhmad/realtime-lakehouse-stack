# Migration 002: Rename `weight` to `product_weight`

**Status:** 🚨 MANUAL INTERVENTION REQUIRED  
**Type:** Column Rename  
**Table:** `inventory.products`  
**Impact:** High - Affects Iceberg, Debezium, and all downstream dbt models  
**Risk Level:** Medium - Data integrity guaranteed if steps followed correctly

---

## ⚠️ Critical Information

**Debezium Behavior:** Column renames are treated as **DROP + ADD**, not as a rename operation. Without proper migration, you will:
- Lose data continuity (old column orphaned, new column starts empty)
- Break downstream queries and analytics
- Create duplicate columns in Iceberg table

**Solution:** Follow the **3-phase migration** below to preserve all data.

---

## 📋 Migration Files Generated

| File | Purpose | Execute In |
|------|---------|------------|
| [002_rename_weight_column.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/002_rename_weight_column.sql) | Postgres migration | PostgreSQL |
| [iceberg_migration_002.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/iceberg_migration_002.sql) | Iceberg schema changes | Trino/Spark |
| [dbt_migration_002.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/dbt_migration_002.sql) | dbt model update guide | dbt SQL files |

---

## 🎯 Step-by-Step Migration Guide

### Phase 1: Preparation (Before Touching Production)

```bash
# 1. Review all generated migration scripts
cat migrations/002_rename_weight_column.sql
cat migrations/iceberg_migration_002.sql
cat migrations/dbt_migration_002.sql

# 2. Notify stakeholders
# - Data team: dbt models will need updates
# - BI team: Dashboards may reference old column name
# - Application team: Ensure they're ready for column name change

# 3. Test in development/staging first (HIGHLY RECOMMENDED)
```

---

### Phase 2: Execute Migration (Production)

#### Step 1: Stop Debezium

```bash
# Stop the Debezium server to prevent data flow during migration
docker-compose stop debezium

# OR if using systemd
# sudo systemctl stop debezium-server
```

**Why?** If Debezium is running when you rename the column in Postgres, it will immediately start writing to a new column in Iceberg, causing data split.

---

#### Step 2: Apply Iceberg Migration

**Execute in Trino/Spark:**
```sql
-- This renames the existing 'weight' column to preserve historical data
ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  RENAME COLUMN weight TO weight_legacy;
```

**Verify:**
```sql
-- Check that column was renamed
DESCRIBE iceberg.icebergdata.debeziumcdc_products;

-- Expected output should show:
-- weight_legacy | double | (old data preserved here)
```

---

#### Step 3: Apply Postgres Migration

```bash
# Apply the column rename in Postgres
psql -h localhost -U testuser -d inventory \
  -f migrations/002_rename_weight_column.sql
```

**Verify:**
```sql
-- In psql
\d+ inventory.products

-- Expected: weight column is now named product_weight
```

---

#### Step 4: Restart Debezium

```bash
# Restart Debezium - it will auto-create the new column in Iceberg
docker-compose start debezium

# OR if using systemd
# sudo systemctl start debezium-server
```

**Monitor logs:**
```bash
# Watch for successful connector start and schema detection
docker-compose logs -f debezium

# Look for: "Schema change detected... adding column product_weight"
```

---

#### Step 5: Verify Data Flow

```sql
-- In Postgres: Insert a test record
INSERT INTO inventory.products (name, product_weight, price)
VALUES ('Test Product', 5.5, 99.99);

-- In Trino/Spark: Check it appears in Iceberg with new column populated
SELECT id, name, product_weight, weight_legacy
FROM iceberg.icebergdata.debeziumcdc_products
WHERE name = 'Test Product';

-- Expected:
-- product_weight = 5.5 (new data)
-- weight_legacy = NULL (no historical data for this new record)
```

---

### Phase 3: Update Downstream Systems

#### Step 6: Update dbt Models

**For all dbt models that reference the `products` table:**

```sql
-- BEFORE (will only see historical data):
SELECT
  id,
  name,
  weight,  -- ❌ Only has data for old records
  price
FROM {{ source('iceberg', 'debeziumcdc_products') }}

-- AFTER (handles both old and new data):
SELECT
  id,
  name,
  COALESCE(product_weight, weight_legacy) AS product_weight,  -- ✅ Works for all records
  price
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

**Files to update:**
```bash
# Find all dbt models referencing the products table
cd dbt_project/
grep -r "debeziumcdc_products\|inventory.products" models/

# Update each file with COALESCE pattern
```

---

#### Step 7: Update schema.yml

```yaml
# models/schema.yml
models:
  - name: enriched_products
    columns:
      - name: product_weight
        description: "Product weight in kg (renamed from weight 2026-01-26)"
        tests:
          - not_null
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 10000
```

---

#### Step 8: Run and Test dbt

```bash
# Run affected models
dbt run --select +products

# Run tests
dbt test --select +products

# If using incremental models, consider full refresh
dbt run --select +products --full-refresh
```

---

## 🔄 Data Backfill Strategy

You now have TWO columns in Iceberg:
- `weight_legacy` - Has all historical data, NULLs for new records
- `product_weight` - Has all new data, NULLs for historical records

### Option 1: Lazy Migration (Recommended)

**Pros:**
- ✅ Instant (metadata-only operation)
- ✅ No expensive file rewrites
- ✅ Zero downtime

**Cons:**
- ❌ Raw Iceberg table has duplicate columns
- ❌ All queries must use `COALESCE`

**Action:** Use `COALESCE` in dbt models (already done in Step 6)

---

### Option 2: Eager Migration (For Small Tables)

**Pros:**
- ✅ Clean raw data (single column)
- ✅ Simple queries downstream

**Cons:**
- ❌ Expensive (rewrites ALL Iceberg files)
- ❌ Can take hours for large tables

**Execute in Trino/Spark:**
```sql
-- Backfill: Copy data from legacy column to new column
UPDATE iceberg.icebergdata.debeziumcdc_products
  SET product_weight = weight_legacy
  WHERE product_weight IS NULL;

-- This query is IDEMPOTENT (safe to re-run)
```

**For very large tables, use chunked backfill:**
```sql
-- Process in batches
UPDATE iceberg.icebergdata.debeziumcdc_products
  SET product_weight = weight_legacy
  WHERE product_weight IS NULL
    AND id BETWEEN 1 AND 1000000;

-- Repeat with next ID range: 1000001 to 2000000, etc.
```

---

## 🧹 Cleanup (After 90+ Days)

Once migration is stable and all queries use the new column:

```sql
-- Drop the legacy column to reclaim storage
ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  DROP COLUMN weight_legacy;

-- Optional: Rewrite files to reclaim storage immediately
-- (Otherwise, wait for scheduled table optimization)
ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  REWRITE DATA FILES;
```

**Before dropping, verify:**
- [ ] No dbt models reference `weight_legacy`
- [ ] No BI dashboards use `weight_legacy`
- [ ] No time-travel queries need it
- [ ] Tested in staging environment

---

## ✅ Post-Migration Checklist

- [ ] Debezium is running and healthy
- [ ] New records flow to `product_weight` column
- [ ] Historical data accessible via `weight_legacy`
- [ ] dbt models updated with `COALESCE` pattern
- [ ] dbt tests passing
- [ ] BI dashboards updated (if applicable)
- [ ] Team notified of successful migration
- [ ] Migration documented in changelog

---

## 🚨 Rollback Plan (If Something Goes Wrong)

If you need to rollback:

```bash
# 1. Stop Debezium
docker-compose stop debezium

# 2. Rename column back in Postgres
psql -h localhost -U testuser -d inventory -c \
  "ALTER TABLE inventory.products RENAME COLUMN product_weight TO weight;"

# 3. Rename column back in Iceberg
# In Trino/Spark:
# ALTER TABLE iceberg.icebergdata.debeziumcdc_products
#   RENAME COLUMN weight_legacy TO weight;

# 4. Restart Debezium
docker-compose start debezium
```

---

## 📊 Migration Timeline Estimate

| Task | Duration | Notes |
|------|----------|-------|
| Preparation & Testing | 30-60 min | Review scripts, test in staging |
| Stop Debezium | 10 sec | Immediate |
| Iceberg Migration | 5 sec | Metadata-only operation |
| Postgres Migration | 5 sec | Fast ALTER TABLE |
| Restart Debezium | 30 sec | Connector startup |
| Verify Data Flow | 5 min | Insert test records |
| Update dbt Models | 30-60 min | Depends on # of models |
| Run dbt Tests | 10-30 min | Depends on data volume |
| **Total Downtime** | **~1 min** | Only while Debezium is stopped |
| **Total Migration** | **2-3 hours** | Including dbt updates |

---

## 📞 Support & Questions

If you encounter issues:
1. Check Debezium logs: `docker-compose logs debezium`
2. Verify Iceberg table schema: `DESCRIBE iceberg.icebergdata.debeziumcdc_products;`
3. Review [Schema Evaluator Skill](.agent/skills/schema-evaluator/SKILL.md)
4. Seek help from data engineering team

---

**Migration Generated:** 2026-01-26  
**Generated By:** Schema Evaluator Skill  
**Next Migration Number:** 003
