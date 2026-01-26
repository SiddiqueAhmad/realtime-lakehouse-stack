# 🚀 Quick Start: Migration 002

## TL;DR - For Experienced Users

```bash
# 1. Stop Debezium
docker-compose stop debezium

# 2. Rename in Iceberg (Trino/Spark):
# ALTER TABLE iceberg.icebergdata.debeziumcdc_products RENAME COLUMN weight TO weight_legacy;

# 3. Apply Postgres migration
psql -h localhost -U testuser -d inventory -f migrations/002_rename_weight_column.sql

# 4. Restart Debezium
docker-compose start debezium

# 5. Update dbt models with COALESCE pattern
# See: migrations/dbt_migration_002.sql
```

---

## 📁 Generated Files

| File | Purpose | When to Use |
|------|---------|-------------|
| **[002_rename_weight_column.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/002_rename_weight_column.sql)** | Postgres DDL | Apply to Postgres DB |
| **[iceberg_migration_002.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/iceberg_migration_002.sql)** | Iceberg DDL | Run in Trino/Spark |
| **[dbt_migration_002.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/dbt_migration_002.sql)** | dbt Guide | Update dbt SQL files |
| **[execute_migration_002.sh](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/execute_migration_002.sh)** | Interactive Script | Guided execution |
| **[MIGRATION_002_SUMMARY.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_SUMMARY.md)** | Full Guide | Complete documentation |
| **[MIGRATION_002_DIAGRAMS.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_DIAGRAMS.md)** | Visual Flows | Understand the process |

---

## ⚡ Execution Options

### Option 1: Guided Interactive Script (Recommended for First-Time)
```bash
./migrations/execute_migration_002.sh
```
This script will:
- ✅ Prompt you at each step
- ✅ Show you exactly what to run
- ✅ Verify completion before proceeding
- ✅ Check Debezium logs

### Option 2: Manual Execution (For CI/CD or Experienced Users)
Follow the TL;DR commands above

### Option 3: Read Full Documentation First
```bash
open migrations/MIGRATION_002_SUMMARY.md
```

---

## 🎯 What This Migration Does

**Query:**
```sql
ALTER TABLE inventory.products RENAME COLUMN weight TO product_weight;
```

**Impact:**
- 🚨 **Risk Level:** MANUAL - Debezium treats rename as DROP + ADD
- ⏱️ **Downtime:** ~4 minutes (Debezium offline only)
- 📊 **Affects:** Iceberg table + All downstream dbt models
- 🔄 **Backfill:** Optional (Lazy vs Eager strategy)

---

## ⚠️ Critical Warnings

1. **DO NOT** apply Postgres migration before Iceberg migration
   - **Why?** Data will split across two columns
   
2. **DO NOT** run without stopping Debezium first
   - **Why?** Connector will fail or lose data

3. **DO** test in staging environment first
   - **Why?** Catch issues before production

4. **DO** update dbt models immediately after
   - **Why?** Queries will break without COALESCE pattern

---

## 📊 Expected Results

### Iceberg Table (After Migration)
```
Column Name      | Type   | Description
-----------------|--------|----------------------------------
id               | BIGINT | Primary key
name             | STRING | Product name
weight_legacy    | DOUBLE | Old data (NULL for new records)
product_weight   | DOUBLE | New data (NULL for old records)
price            | DOUBLE | Price
```

### dbt Query Pattern
```sql
SELECT
  id,
  name,
  COALESCE(product_weight, weight_legacy) AS product_weight,
  price
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

---

## 🆘 Troubleshooting

### Debezium Won't Start After Migration
```bash
# Check logs
docker-compose logs debezium

# Common fix: Schema mismatch
# Solution: Verify Iceberg column was renamed to weight_legacy
```

### dbt Models Failing
```bash
# Error: "column weight does not exist"
# Solution: Update models with COALESCE pattern from dbt_migration_002.sql
```

### Data Not Flowing to new Column
```bash
# Verify in Iceberg:
# SELECT * FROM iceberg.icebergdata.debeziumcdc_products ORDER BY id DESC LIMIT 10;

# If product_weight is NULL for new records:
# - Debezium might not have restarted properly
# - Check connector status
```

---

## ✅ Success Criteria

Migration is successful when:
- [ ] Debezium is running without errors
- [ ] New records populate `product_weight` column
- [ ] Historical records accessible via `weight_legacy`
- [ ] dbt models run without errors
- [ ] dbt tests pass
- [ ] BI dashboards updated (if applicable)

---

## 📞 Need Help?

1. **Read Full Documentation:** [MIGRATION_002_SUMMARY.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_SUMMARY.md)
2. **View Diagrams:** [MIGRATION_002_DIAGRAMS.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_DIAGRAMS.md)
3. **Check Schema Evaluator Skill:** [.agent/skills/schema-evaluator/SKILL.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/.agent/skills/schema-evaluator/SKILL.md)

---

## 🚦 When to Execute

**Best Time:**
- ✅ Low-traffic hours
- ✅ After testing in staging
- ✅ When team is available to monitor

**Avoid:**
- ❌ Peak business hours
- ❌ Right before holidays
- ❌ During other major deployments

---

**Ready to execute?** Run `./migrations/execute_migration_002.sh` to begin! 🎯
