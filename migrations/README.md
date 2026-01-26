# Migrations Directory

This directory contains version-controlled Postgres schema migrations for your realtime-lakehouse-stack project.

## Purpose

Schema migrations in this directory are analyzed by the **Schema Evaluation Skill** to determine compatibility with Debezium-Iceberg schema evolution before being applied to your production database.

## Migration Workflow

### 1. Create a Migration

Create a new SQL file with sequential numbering:

```bash
# Format: <number>_<descriptive_name>.sql
migrations/001_add_customer_phone.sql
migrations/002_add_product_categories.sql
migrations/003_rename_weight_column.sql
```

**Example Migration:**
```sql
-- migrations/001_add_customer_phone.sql
-- Add phone number tracking to customers

ALTER TABLE inventory.customers ADD COLUMN phone VARCHAR(20);
ALTER TABLE inventory.customers ADD COLUMN phone_verified BOOLEAN DEFAULT FALSE;
```

### 2. Evaluate the Migration

Run the schema evaluator to check compatibility:

```bash
./scripts/evaluate-migrations.sh
```

This will:
- ✅ Identify safe migrations (automatic handling)
- ⚠️  Warn about migrations requiring caution
- 🚨 Flag migrations requiring manual intervention

### 3. Generate Migration Scripts (if needed)

For migrations requiring manual intervention, generate helper scripts:

```bash
# For Iceberg table migrations
python3 .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py \
  migrations/003_rename_weight_column.sql \
  --output iceberg_migration_003.sql

# For dbt model updates
python3 .agent/skills/schema-evaluator/scripts/generate_dbt_migration.py \
  migrations/003_rename_weight_column.sql \
  --output dbt_migration_003.sql
```

### 4. Apply the Migration

**For Safe Migrations (Automatic):**
```bash
# Apply directly to Postgres
psql -h localhost -U testuser -d inventory -f migrations/001_add_customer_phone.sql

# Debezium will automatically update Iceberg tables
# No manual intervention needed!
```

**For Manual Migrations:**
1. Stop Debezium server
2. Apply Iceberg migration (from generated script)
3. Apply Postgres migration
4. Restart Debezium
5. Update dbt models (from generated guide)
6. Verify data flows correctly

## Naming Conventions

- **Sequential numbering**: `001`, `002`, `003`, etc.
- **Descriptive names**: Use underscores, lowercase
- **SQL extension**: Always `.sql`

**Good Examples:**
- `001_add_customer_phone.sql`
- `002_create_categories_table.sql`
- `003_add_price_decimal_precision.sql`

**Avoid:**
- `migration.sql` (not descriptive)
- `add customer phone.sql` (spaces)
- `AddCustomerPhone.sql` (PascalCase)

## Migration Types

### ✅ Safe (Automatic Handling)

These migrations work automatically with Debezium-Iceberg:

```sql
-- Adding columns
ALTER TABLE customers ADD COLUMN email_verified BOOLEAN DEFAULT FALSE;

-- Safe type expansions
ALTER TABLE products ALTER COLUMN id TYPE BIGINT;  -- int -> bigint
ALTER TABLE orders ALTER COLUMN price TYPE DOUBLE PRECISION;  -- int -> double
ALTER TABLE customers ALTER COLUMN name TYPE VARCHAR(500);  -- varchar(255) -> varchar(500)
```

### ⚠️ Caution (Review Recommended)

These work but may have side effects:

```sql
-- Dropping columns (column persists in Iceberg with NULLs)
ALTER TABLE products DROP COLUMN old_description;

-- Nullable changes (not enforced in Iceberg)
ALTER TABLE customers ALTER COLUMN email DROP NOT NULL;
```

### 🚨 Manual Intervention Required

These require migration scripts for downstream services:

```sql
-- Column renames (treated as drop + add)
ALTER TABLE products RENAME COLUMN weight TO product_weight;

-- Incompatible type changes
ALTER TABLE orders ALTER COLUMN order_date TYPE TIMESTAMP;  -- date -> timestamp
ALTER TABLE products ALTER COLUMN quantity TYPE SMALLINT;   -- int -> smallint (narrowing)

-- Precision reductions
ALTER TABLE products ALTER COLUMN price TYPE DECIMAL(8,2);  -- decimal(10,2) -> decimal(8,2)
```

## Integration with Git

**All migrations should be committed to version control before applying!**

```bash
# Create and evaluate migration
./scripts/evaluate-migrations.sh

# If safe, commit
git add migrations/001_add_customer_phone.sql
git commit -m "Add phone number fields to customers table"

# Apply migration
psql -h localhost -U testuser -d inventory -f migrations/001_add_customer_phone.sql
```

## Future: GitHub Actions Integration

In the future, we'll add GitHub Actions to automatically evaluate migrations on PR:

```yaml
# .github/workflows/evaluate-migrations.yml (coming soon)
name: Evaluate Schema Migrations
on: [pull_request]
jobs:
  evaluate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Schema Evaluator
        run: ./scripts/evaluate-migrations.sh
```

## Troubleshooting

### "No migrations to evaluate"
- Make sure your SQL files are in the `migrations/` directory
- Check that files have `.sql` extension
- Verify file permissions (should be readable)

### "Manual intervention required"
- Generate migration scripts using the provided commands
- Review the generated scripts carefully
- Follow the step-by-step migration process
- Test in development/staging first!

### "Analyzer script not found"
- Ensure the schema-evaluator skill is in `.agent/skills/schema-evaluator/`
- Check that Python scripts have execute permissions
- Verify you're running from the project root

## References

- [Schema Evaluator Skill Documentation](../.agent/skills/schema-evaluator/SKILL.md)
- [Debezium-Iceberg Schema Evolution](https://memiiso.github.io/debezium-server-iceberg/iceberg/#automatic-schema-change-handling)
- [Debezium-Iceberg Migration Guide](https://memiiso.github.io/debezium-server-iceberg/migration/)
