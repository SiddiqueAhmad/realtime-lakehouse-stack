# Migration 002: Visual Flow Diagram

## Data Flow - Before Migration

```mermaid
graph LR
    A[Postgres: products] -->|CDC| B[Debezium]
    B -->|Replication| C[Iceberg: debeziumcdc_products]
    C -->|Query| D[dbt Models]
    D -->|Transform| E[Analytics]
    
    style A fill:#4CAF50
    style C fill:#4CAF50
    
    subgraph "Column Status"
    A1["weight column ✅"]
    C1["weight column ✅"]
    end
```

---

## ⚠️ What Happens WITHOUT Proper Migration

```mermaid
graph TB
    A[❌ Just run ALTER TABLE in Postgres] --> B[Debezium sees new column]
    B --> C[Creates NEW column in Iceberg]
    C --> D{Result}
    D --> E[Old column: weight with NULLs]
    D --> F[New column: product_weight with NULLs]
    D --> G[❌ Data split across 2 columns!]
    
    style A fill:#f44336
    style G fill:#f44336
```

---

## ✅ Correct Migration Flow

```mermaid
graph TB
    Start[Start Migration] --> Stop[1. Stop Debezium]
    Stop --> Iceberg[2. Rename in Iceberg:<br/>weight → weight_legacy]
    Iceberg --> Postgres[3. Rename in Postgres:<br/>weight → product_weight]
    Postgres --> Restart[4. Restart Debezium]
    Restart --> Auto[5. Debezium auto-creates<br/>product_weight in Iceberg]
    Auto --> Result{Iceberg Table State}
    Result --> Old[weight_legacy:<br/>Historical data ✅<br/>New records: NULL]
    Result --> New[product_weight:<br/>New data ✅<br/>Old records: NULL]
    Result --> DBT[6. Update dbt:<br/>COALESCE product_weight, weight_legacy]
    DBT --> Done[✅ Migration Complete]
    
    style Start fill:#2196F3
    style Done fill:#4CAF50
    style DBT fill:#FF9800
```

---

## Migration Timeline

```mermaid
gantt
    title Migration 002 Execution Timeline
    dateFormat  HH:mm
    axisFormat %H:%M
    
    section Preparation
    Review Scripts           :done, prep1, 00:00, 30m
    Test in Staging         :done, prep2, after prep1, 30m
    
    section Downtime Window
    Stop Debezium           :crit, down1, after prep2, 1m
    Iceberg Migration       :crit, down2, after down1, 1m
    Postgres Migration      :crit, down3, after down2, 1m
    Restart Debezium        :crit, down4, after down3, 1m
    
    section Verification
    Verify Data Flow        :active, verify1, after down4, 10m
    
    section dbt Updates
    Update Models           :dbt1, after verify1, 45m
    Run dbt Tests           :dbt2, after dbt1, 15m
```

**Total Downtime: ~4 minutes** (Debezium stopped)

---

## Schema Evolution

```mermaid
graph LR
    subgraph "Before Migration"
    A1[Postgres] --> B1[weight NUMERIC]
    C1[Iceberg] --> D1[weight DOUBLE]
    end
    
    subgraph "During Migration"
    A2[Postgres] -.->|Debezium OFF| B2[...]
    C2[Iceberg] --> D2[weight → weight_legacy]
    end
    
    subgraph "After Migration"
    A3[Postgres] --> B3[product_weight NUMERIC]
    C3[Iceberg] --> D3[weight_legacy DOUBLE]
    C3 --> E3[product_weight DOUBLE]
    end
    
    style A2 fill:#f44336
    style A3 fill:#4CAF50
    style C3 fill:#4CAF50
```

---

## dbt Query Pattern

### Before Migration
```sql
SELECT
  id,
  name,
  weight,  -- ❌ Single column
  price
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

### After Migration (Lazy Strategy)
```sql
SELECT
  id,
  name,
  COALESCE(product_weight, weight_legacy) AS product_weight,  -- ✅ Handles both
  price
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

### After Eager Backfill (Optional)
```sql
SELECT
  id,
  name,
  product_weight,  -- ✅ Single column (after backfill)
  price
FROM {{ source('iceberg', 'debeziumcdc_products') }}
```

---

## Decision Tree: Lazy vs Eager

```mermaid
graph TD
    Start{Table Size?} -->|< 1GB| Small[Consider Eager]
    Start -->|> 1GB| Large[Use Lazy]
    
    Small --> Q1{Need clean<br/>raw data?}
    Q1 -->|Yes| Eager[✅ Eager Migration<br/>+ Backfill]
    Q1 -->|No| Lazy2[✅ Lazy Migration<br/>+ COALESCE]
    
    Large --> Q2{Can afford<br/>hours of backfill?}
    Q2 -->|No| Lazy[✅ Lazy Migration<br/>+ COALESCE]
    Q2 -->|Yes| Eager2[⚠️ Eager Migration<br/>+ Chunked Backfill]
    
    style Lazy fill:#4CAF50
    style Lazy2 fill:#4CAF50
    style Eager fill:#FF9800
    style Eager2 fill:#FF9800
```

---

## Rollback Procedure

```mermaid
graph TB
    Issue[❌ Issue Detected] --> Stop[1. Stop Debezium]
    Stop --> RevertPG[2. Revert Postgres:<br/>product_weight → weight]
    RevertPG --> RevertIceberg[3. Revert Iceberg:<br/>weight_legacy → weight]
    RevertIceberg --> Restart[4. Restart Debezium]
    Restart --> Verify[5. Verify Old Flow]
    Verify --> Done[✅ Rolled Back]
    
    style Issue fill:#f44336
    style Done fill:#4CAF50
```

---

## Files Generated

```
migrations/
├── 002_rename_weight_column.sql       # Postgres migration
├── iceberg_migration_002.sql          # Iceberg schema change
├── dbt_migration_002.sql              # dbt update guide
├── MIGRATION_002_SUMMARY.md           # Full documentation (this file)
└── execute_migration_002.sh           # Interactive execution script
```

---

## Quick Reference Commands

### Execute Migration
```bash
# Interactive guided migration
./migrations/execute_migration_002.sh

# Manual execution
docker-compose stop debezium
# Run Iceberg migration in Trino/Spark
psql -h localhost -U testuser -d inventory -f migrations/002_rename_weight_column.sql
docker-compose start debezium
```

### Verify Migration
```sql
-- Postgres
\d+ inventory.products

-- Iceberg (Trino/Spark)
DESCRIBE iceberg.icebergdata.debeziumcdc_products;
```

### Update dbt
```bash
# Find models to update
grep -r "weight" dbt_project/models/

# Run updated models
dbt run --select +products
dbt test --select +products
```

---

**Generated:** 2026-01-26  
**Schema Evaluator Skill Version:** 1.0  
**Next Steps:** Follow [MIGRATION_002_SUMMARY.md](file:///Users/siddiqueahmad/projects/realtime-lakehouse-stack/migrations/MIGRATION_002_SUMMARY.md)
