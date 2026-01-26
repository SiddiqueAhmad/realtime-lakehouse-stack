# 📁 Migration 002: Complete Package Index

## Migration Details

**Query:** `ALTER TABLE inventory.products RENAME COLUMN weight TO product_weight;`  
**Status:** 🚨 MANUAL INTERVENTION REQUIRED  
**Generated:** 2026-01-26  
**Risk Level:** Medium  
**Estimated Downtime:** ~4 minutes

---

## 📚 Documentation Files

### 🚀 Start Here
| File | Purpose | When to Read |
|------|---------|-------------|
| **[QUICKSTART_002.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/QUICKSTART_002.md)** | Quick start guide with TL;DR | **Read this first!** |
| **[MIGRATION_002_SUMMARY.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_SUMMARY.md)** | Complete step-by-step guide | Deep dive into migration process |
| **[MIGRATION_002_DIAGRAMS.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_DIAGRAMS.md)** | Visual flow diagrams | Understand the architecture |

### 📝 Migration Scripts
| File | Purpose | Execute In |
|------|---------|------------|
| **[002_rename_weight_column.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/002_rename_weight_column.sql)** | Postgres DDL migration | PostgreSQL |
| **[iceberg_migration_002.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/iceberg_migration_002.sql)** | Iceberg schema update | Trino/Spark |
| **[dbt_migration_002.sql](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/dbt_migration_002.sql)** | dbt model update guide | dbt project |

### 🛠️ Helper Scripts
| File | Purpose | Usage |
|------|---------|-------|
| **[execute_migration_002.sh](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/execute_migration_002.sh)** | Interactive execution script | `./migrations/execute_migration_002.sh` |
| **[verify_migration_002.sh](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/verify_migration_002.sh)** | Post-migration verification | `./migrations/verify_migration_002.sh` |

---

## 🎯 Quick Start Commands

### For First-Time Migration
```bash
# 1. Read the quick start guide
open migrations/QUICKSTART_002.md

# 2. Run interactive migration
./migrations/execute_migration_002.sh

# 3. Verify everything works
./migrations/verify_migration_002.sh
```

### For Experienced Users
```bash
# 1. Stop Debezium
docker-compose stop debezium

# 2. Apply Iceberg migration (in Trino/Spark)
# ALTER TABLE iceberg.icebergdata.debeziumcdc_products RENAME COLUMN weight TO weight_legacy;

# 3. Apply Postgres migration
psql -h localhost -U testuser -d inventory -f migrations/002_rename_weight_column.sql

# 4. Restart Debezium
docker-compose start debezium

# 5. Verify
./migrations/verify_migration_002.sh
```

---

## 📊 What This Migration Does

### Before Migration
```
Postgres: products.weight
    ↓ (CDC)
Iceberg: debeziumcdc_products.weight
    ↓
dbt: SELECT weight FROM ...
```

### After Migration
```
Postgres: products.product_weight
    ↓ (CDC)
Iceberg:
  - weight_legacy (historical data)
  - product_weight (new data)
    ↓
dbt: SELECT COALESCE(product_weight, weight_legacy) AS product_weight
```

---

## ⚠️ Critical Warnings

1. **DO NOT skip Iceberg migration** - Data will be lost
2. **DO NOT run without stopping Debezium** - Connector will fail
3. **DO test in staging first** - Catch issues early
4. **DO update dbt models** - Queries will break otherwise

---

## 🎓 Learning Path

### If you're new to schema migrations:
1. Start with **[QUICKSTART_002.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/QUICKSTART_002.md)**
2. Read **[MIGRATION_002_DIAGRAMS.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_DIAGRAMS.md)** to understand the flow
3. Review **[MIGRATION_002_SUMMARY.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_SUMMARY.md)** for complete details
4. Use **[execute_migration_002.sh](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/execute_migration_002.sh)** for guided execution

### If you're experienced:
1. Skim **[QUICKSTART_002.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/QUICKSTART_002.md)** for TL;DR
2. Review the three SQL files
3. Execute manually following the checklist
4. Run **[verify_migration_002.sh](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/verify_migration_002.sh)**

---

## 📋 Pre-Migration Checklist

Before executing this migration, ensure:

- [ ] You've read at least the QUICKSTART_002.md
- [ ] Migration tested in staging/development environment
- [ ] Team notified (data engineers, BI team, application team)
- [ ] Maintenance window scheduled (if needed)
- [ ] Backup of Postgres database taken
- [ ] Debezium connector is currently healthy
- [ ] You have access to:
  - [ ] PostgreSQL (psql)
  - [ ] Iceberg query engine (Trino/Spark)
  - [ ] dbt project
  - [ ] Docker/Debezium control

---

## ✅ Post-Migration Checklist

After executing the migration:

- [ ] Debezium is running without errors
- [ ] New data flows to `product_weight` column in Iceberg
- [ ] Historical data accessible via `weight_legacy` column
- [ ] Ran `./migrations/verify_migration_002.sh` successfully
- [ ] Updated all dbt models with COALESCE pattern
- [ ] dbt tests passing: `dbt test --select +products`
- [ ] BI dashboards updated (if applicable)
- [ ] Monitoring set up for 24-48 hours
- [ ] Team notified of successful migration
- [ ] Migration documented in changelog/wiki

---

## 🚨 Troubleshooting

### Debezium won't start
```bash
# Check logs
docker-compose logs debezium

# Common issue: Schema mismatch
# Fix: Verify Iceberg column renamed to weight_legacy
```

### New data not flowing to product_weight
```bash
# Verify in Iceberg
# SELECT * FROM iceberg.icebergdata.debeziumcdc_products ORDER BY id DESC LIMIT 5;

# If product_weight is NULL:
# 1. Check Debezium connector status
# 2. Verify Postgres column is named product_weight
# 3. Look for errors in Debezium logs
```

### dbt models failing
```bash
# Error: "column weight does not exist"
# Fix: Update models with COALESCE pattern from dbt_migration_002.sql

# Run:
dbt run --select +products --full-refresh
```

### Historical data missing
```bash
# This should NOT happen if you followed the migration steps
# If it does, you may need to rollback (see MIGRATION_002_SUMMARY.md)
```

---

## 🔄 Rollback Plan

If migration fails, see **MIGRATION_002_SUMMARY.md** section "Rollback Plan"

Quick rollback:
```bash
# 1. Stop Debezium
docker-compose stop debezium

# 2. Revert Postgres
psql -c "ALTER TABLE inventory.products RENAME COLUMN product_weight TO weight;"

# 3. Revert Iceberg (in Trino/Spark)
# ALTER TABLE iceberg.icebergdata.debeziumcdc_products RENAME COLUMN weight_legacy TO weight;

# 4. Restart Debezium
docker-compose start debezium
```

---

## 📊 File Generation Log

All files were generated by the **Schema Evaluator Skill** on **2026-01-26**

```bash
# Files generated:
migrations/
├── 002_rename_weight_column.sql       # Postgres DDL
├── iceberg_migration_002.sql          # Iceberg DDL
├── dbt_migration_002.sql              # dbt guide
├── execute_migration_002.sh           # Interactive script
├── verify_migration_002.sh            # Verification script
├── QUICKSTART_002.md                  # Quick start
├── MIGRATION_002_SUMMARY.md           # Complete guide
├── MIGRATION_002_DIAGRAMS.md          # Visual diagrams
└── INDEX_002.md                       # This file
```

---

## 🔗 Related Resources

- [Schema Evaluator Skill Documentation](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/.agent/skills/schema-evaluator/SKILL.md)
- [Debezium-Iceberg Schema Evolution](https://memiiso.github.io/debezium-server-iceberg/iceberg/#automatic-schema-change-handling)
- [Migrations README](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/README.md)

---

## 📞 Support

If you encounter issues not covered in the documentation:

1. Review logs: `docker-compose logs debezium`
2. Check Iceberg schema: `DESCRIBE iceberg.icebergdata.debeziumcdc_products;`
3. Consult Schema Evaluator Skill documentation
4. Reach out to data engineering team

---

## 🎯 Success Criteria

This migration is considered successful when:

1. ✅ Debezium running without errors
2. ✅ New records populate `product_weight`
3. ✅ Historical records accessible via `weight_legacy`
4. ✅ dbt models updated and tests passing
5. ✅ BI dashboards functioning correctly
6. ✅ No data loss or integrity issues
7. ✅ Monitoring shows healthy pipeline

---

## 📈 Next Steps After Migration

1. **Monitor for 24-48 hours** - Watch for any unexpected issues
2. **Decide on backfill strategy** - Lazy (COALESCE) vs Eager (UPDATE)
3. **Update documentation** - Team wiki, runbooks, etc.
4. **Plan ghost column cleanup** - After 90+ days if using Lazy strategy
5. **Share learnings** - Document any issues/improvements for next migration

---

**Ready to begin?** Start with **[QUICKSTART_002.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/QUICKSTART_002.md)** 🚀
