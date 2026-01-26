# Schema Evaluator Skill

Evaluates Postgres schema migrations for compatibility with Debezium-Iceberg schema evolution and generates migration scripts for downstream services.

## Quick Start

1. **Create a migration**:
   ```bash
   echo "ALTER TABLE inventory.customers ADD COLUMN phone VARCHAR(20);" > migrations/001_add_phone.sql
   ```

2. **Evaluate it**:
   ```bash
   ./scripts/evaluate-migrations.sh
   ```

3. **If manual migration needed, generate scripts**:
   ```bash
   python3 .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py migrations/002_rename.sql
   python3 .agent/skills/schema-evaluator/scripts/generate_dbt_migration.py migrations/002_rename.sql
   ```

## Documentation

- **Complete Guide**: [SKILL.md](SKILL.md)
- **Migration Workflow**: [../../migrations/README.md](../../migrations/README.md)
- **Examples**: See `examples/` directory

## What It Does

✅ **Analyzes** SQL migrations for Debezium-Iceberg compatibility  
✅ **Classifies** changes as Safe/Caution/Manual  
✅ **Generates** ready-to-use migration scripts for Iceberg tables  
✅ **Provides** dbt model update guidance  

## Files

- `SKILL.md` - Complete skill documentation
- `scripts/schema_rules.py` - Type compatibility rules
- `scripts/analyze_migration.py` - Migration analyzer
- `scripts/generate_iceberg_migration.py` - Iceberg script generator
- `scripts/generate_dbt_migration.py` - dbt guide generator
- `examples/` - Example migrations showing different scenarios
