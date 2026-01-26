#!/usr/bin/env python3
"""
Generate dbt Model Migration Scripts

This script analyzes a Postgres migration and suggests updates to dbt models
to handle upstream schema changes.
"""

import sys
from pathlib import Path
from typing import List, Dict
from analyze_migration import MigrationAnalyzer, SchemaChange
from schema_rules import ChangeStatus, ChangeType


class DbtMigrationGenerator:
    """Generates dbt model updates from Postgres schema changes."""
    
    def __init__(self, analyzer: MigrationAnalyzer):
        """
        Initialize the generator.
        
        Args:
            analyzer: MigrationAnalyzer with parsed changes
        """
        self.analyzer = analyzer
    
    def generate_column_rename_guidance(self, change: SchemaChange) -> List[str]:
        """Generate dbt model updates for column renames."""
        # Extract old and new column names
        if ' → ' in change.column_name:
            old_col, new_col = change.column_name.split(' → ')
        else:
            old_col = change.column_name
            new_col = f"{old_col}_new"
        
        table = change.table_name.split('.')[-1]  # Remove schema prefix
        
        return [
            f"-- dbt Model Update: Column Rename ({old_col} → {new_col})",
            f"-- Table: {change.table_name}",
            "",
            "-- Update your dbt SELECT to use COALESCE for backward compatibility:",
            f"COALESCE({new_col}, {old_col}_legacy) AS {new_col},",
            "",
            "-- This allows the model to work with both old and new data",
            "-- Old records: {old_col}_legacy has data, {new_col} is NULL",
            "-- New records: {new_col} has data, {old_col}_legacy is NULL",
            "",
            f"-- Full example for a dbt model using debeziumcdc_{table}:",
            "-- SELECT",
            "--   order_id,",
            "--   product_id,",
            f"--   COALESCE({new_col}, {old_col}_legacy) AS {new_col},",
            "--   quantity",
            f"-- FROM {{{{ source('iceberg', 'debeziumcdc_{table}') }}}}",
            ""
        ]
    
    def generate_type_change_guidance(self, change: SchemaChange) -> List[str]:
        """Generate dbt model updates for type changes."""
        column = change.column_name
        old_type = change.from_type or 'previous_type'
        new_type = change.to_type
        table = change.table_name.split('.')[-1]
        
        return [
            f"-- dbt Model Update: Type Change ({column}: {old_type} → {new_type})",
            f"-- Table: {change.table_name}",
            "",
            "-- Use COALESCE with type casting for backward compatibility:",
            f"COALESCE(",
            f"  {column},",
            f"  CAST({column}_legacy AS {new_type})",
            f") AS {column},",
            "",
            "-- Note: Review the CAST function for your specific types",
            "-- Some conversions may need custom logic",
            "",
            f"-- If the conversion is straightforward, you can also use:",
            f"-- COALESCE({column}, {column}_legacy::{new_type}) AS {column},",
            ""
        ]
    
    def generate_new_column_guidance(self, change: SchemaChange) -> List[str]:
        """Generate dbt model updates for new columns."""
        column = change.column_name
        col_type = change.to_type
        table = change.table_name.split('.')[-1]
        
        return [
            f"-- dbt Model Update: New Column Added ({column})",
            f"-- Table: {change.table_name}",
            "",
            f"-- Simply add the new column to your SELECT:",
            f"{column},  -- {col_type}",
            "",
            "-- Update your schema.yml if you have column-level documentation:",
            "# models/schema.yml",
            f"#   - name: {column}",
            f"#     description: \"Description of {column}\"",
            "#     tests:",
            "#       - not_null  # Add appropriate tests",
            ""
        ]
    
    def generate_dropped_column_guidance(self, change: SchemaChange) -> List[str]:
        """Generate dbt model updates for dropped columns."""
        column = change.column_name
        table = change.table_name.split('.')[-1]
        
        return [
            f"-- dbt Model Update: Column Dropped ({column})",
            f"-- Table: {change.table_name}",
            "",
            "-- Decision needed: Should you keep this column in your dbt models?",
            "",
            "-- Option 1: Remove from dbt models (if truly no longer needed)",
            f"-- Remove {column} from your SELECT statement",
            "",
            "-- Option 2: Keep for historical analysis (column still exists in Iceberg)",
            f"-- {column},  -- Note: NULL for all new records after migration",
            "",
            "-- Option 3: Use COALESCE with a default value",
            f"-- COALESCE({column}, 'UNKNOWN') AS {column},  -- For backward compat",
            ""
        ]
    
    def generate_schema_yml_update(self) -> List[str]:
        """Generate schema.yml updates."""
        lines = [
            "# Update your dbt schema.yml file",
            "# Location: models/schema.yml or models/<layer>/schema.yml",
            "",
            "version: 2",
            "",
            "models:",
        ]
        
        # Group changes by table
        tables: Dict[str, List[SchemaChange]] = {}
        for change in self.analyzer.changes:
            table = change.table_name.split('.')[-1]
            if table not in tables:
                tables[table] = []
            tables[table].append(change)
        
        for table, changes in tables.items():
            lines.append(f"  - name: your_model_using_{table}")
            lines.append("    description: \"Update description if schema changed significantly\"")
            lines.append("    columns:")
            
            for change in changes:
                if change.change_type == ChangeType.ADD_COLUMN:
                    col = change.column_name
                    lines.append(f"      - name: {col}")
                    lines.append(f"        description: \"New column: {col}\"")
                elif change.change_type == ChangeType.RENAME_COLUMN:
                    if ' → ' in change.column_name:
                        _, new_col = change.column_name.split(' → ')
                        lines.append(f"      - name: {new_col}")
                        lines.append(f"        description: \"Renamed from {change.column_name}\"")
            
            lines.append("")
        
        return lines
    
    def generate_migration_guide(self) -> str:
        """Generate the complete dbt migration guide."""
        lines = [
            "-- dbt Model Migration Guide",
            f"-- Generated for: {self.analyzer.migration_file.name}",
            "",
            "-- This guide helps you update your dbt models to handle upstream",
            "-- schema changes from Postgres → Debezium → Iceberg",
            "",
            "-- ═══════════════════════════════════════════════════════════════",
            ""
        ]
        
        # Check if there are any changes that affect dbt
        relevant_changes = [
            c for c in self.analyzer.changes 
            if c.change_type in (
                ChangeType.ADD_COLUMN, ChangeType.DROP_COLUMN,
                ChangeType.RENAME_COLUMN, ChangeType.ALTER_TYPE
            )
        ]
        
        if not relevant_changes:
            lines.extend([
                "-- ✅ No dbt model updates required!",
                "-- Schema changes don't affect dbt models",
                ""
            ])
            return '\n'.join(lines)
        
        for change in relevant_changes:
            if change.change_type == ChangeType.RENAME_COLUMN:
                lines.extend(self.generate_column_rename_guidance(change))
            
            elif change.change_type == ChangeType.ALTER_TYPE:
                lines.extend(self.generate_type_change_guidance(change))
            
            elif change.change_type == ChangeType.ADD_COLUMN:
                lines.extend(self.generate_new_column_guidance(change))
            
            elif change.change_type == ChangeType.DROP_COLUMN:
                lines.extend(self.generate_dropped_column_guidance(change))
            
            lines.extend(["", "-- " + "─" * 60, ""])
        
        # Schema YAML updates
        lines.extend([
            "",
            "-- ═══════════════════════════════════════════════════════════════",
            "-- SCHEMA.YML UPDATES",
            "-- ═══════════════════════════════════════════════════════════════",
            ""
        ])
        lines.extend(self.generate_schema_yml_update())
        
        # Footer with steps
        lines.extend([
            "",
            "-- ═══════════════════════════════════════════════════════════════",
            "-- RECOMMENDED WORKFLOW:",
            "-- ═══════════════════════════════════════════════════════════════",
            "-- 1. Review the suggested SQL updates above",
            "-- 2. Update your dbt model SQL files (models/silver/*.sql, etc.)",
            "-- 3. Update schema.yml with new/renamed columns",
            "-- 4. Test locally: dbt run --select <affected_models>",
            "-- 5. Run tests: dbt test --select <affected_models>",
            "-- 6. If using incremental models, consider: dbt run --full-refresh",
            "-- 7. Deploy to production after validation",
            ""
        ])
        
        return '\n'.join(lines)


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: python generate_dbt_migration.py <migration_file.sql> [--output <file>]")
        print("\nExample:")
        print("  python generate_dbt_migration.py migrations/002_rename_weight.sql")
        print("  python generate_dbt_migration.py migrations/002_rename_weight.sql --output dbt_migration_002.sql")
        sys.exit(1)
    
    migration_file = Path(sys.argv[1])
    
    if not migration_file.exists():
        print(f"❌ Error: Migration file not found: {migration_file}")
        sys.exit(1)
    
    # Parse output file option
    output_file = None
    if '--output' in sys.argv:
        idx = sys.argv.index('--output')
        if idx + 1 < len(sys.argv):
            output_file = Path(sys.argv[idx + 1])
    
    # Analyze the migration
    print(f"📋 Analyzing {migration_file.name}...")
    analyzer = MigrationAnalyzer(migration_file)
    analyzer.parse_sql_file()
    
    # Generate dbt migration guide
    generator = DbtMigrationGenerator(analyzer)
    guide = generator.generate_migration_guide()
    
    # Output
    if output_file:
        output_file.write_text(guide)
        print(f"✅ dbt migration guide written to: {output_file}")
        print(f"\n📄 Review the guide and update your dbt models:")
        print(f"   {output_file}")
    else:
        print("\n" + "═" * 70)
        print(guide)
        print("═" * 70)
    
    print()


if __name__ == '__main__':
    main()
