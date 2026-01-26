#!/usr/bin/env python3
"""
Generate Iceberg Migration Scripts

This script analyzes a Postgres migration and generates the corresponding
Spark SQL commands needed to manually migrate Iceberg tables when automatic
schema evolution cannot handle the changes.
"""

import sys
from pathlib import Path
from typing import List
from analyze_migration import MigrationAnalyzer, SchemaChange
from schema_rules import ChangeStatus, ChangeType


class IcebergMigrationGenerator:
    """Generates Iceberg migration scripts from Postgres schema changes."""
    
    def __init__(self, analyzer: MigrationAnalyzer, catalog: str = "iceberg", 
                 namespace: str = "icebergdata", table_prefix: str = "debeziumcdc_"):
        """
        Initialize the generator.
        
        Args:
            analyzer: MigrationAnalyzer with parsed changes
            catalog: Iceberg catalog name
            namespace: Iceberg namespace/database
            table_prefix: Prefix added to table names by Debezium
        """
        self.analyzer = analyzer
        self.catalog = catalog
        self.namespace = namespace
        self.table_prefix = table_prefix
    
    def _get_iceberg_table_name(self, pg_table: str) -> str:
        """
        Convert Postgres table name to Iceberg table name.
        
        Args:
            pg_table: Postgres table name (may include schema)
        
        Returns:
            Fully qualified Iceberg table name
        """
        # Remove schema prefix if present (e.g., "inventory.customers" -> "customers")
        if '.' in pg_table:
            pg_table = pg_table.split('.')[-1]
        
        return f"{self.catalog}.{self.namespace}.{self.table_prefix}{pg_table}"
    
    def generate_rename_column_migration(self, change: SchemaChange) -> List[str]:
        """Generate SQL for column rename migration."""
        table = self._get_iceberg_table_name(change.table_name)
        
        # Extract old and new column names
        if ' → ' in change.column_name:
            old_col, new_col = change.column_name.split(' → ')
        else:
            # Fallback
            old_col = change.column_name
            new_col = f"{old_col}_new"
        
        return [
            f"-- Column Rename Migration: {old_col} → {new_col}",
            f"-- Strategy: Rename old column to preserve historical data",
            f"-- New column will be auto-created by Debezium",
            "",
            f"ALTER TABLE {table}",
            f"  RENAME COLUMN {old_col} TO {old_col}_legacy;",
            "",
            "-- After restarting Debezium, the new column will be created automatically",
            "-- Optional: Backfill data from legacy column to new column:",
            f"-- UPDATE {table}",
            f"--   SET {new_col} = {old_col}_legacy",
            f"--   WHERE {new_col} IS NULL;",
            ""
        ]
    
    def generate_type_change_migration(self, change: SchemaChange) -> List[str]:
        """Generate SQL for type change migration."""
        table = self._get_iceberg_table_name(change.table_name)
        column = change.column_name
        old_type = change.from_type or 'current_type'
        new_type = change.to_type
        
        return [
            f"-- Type Change Migration: {column} ({old_type} → {new_type})",
            f"-- Strategy: Rename old column, new column will be auto-created",
            "",
            f"ALTER TABLE {table}",
            f"  RENAME COLUMN {column} TO {column}_legacy;",
            "",
            "-- After restarting Debezium, new column will be created with correct type",
            "-- Optional: Migrate data with type conversion:",
            f"-- UPDATE {table}",
            f"--   SET {column} = CAST({column}_legacy AS {new_type})",
            f"--   WHERE {column} IS NULL;",
            "",
            f"-- Note: Review the CAST function for {old_type} → {new_type}",
            "-- Some conversions may require custom logic (e.g., date → timestamp)",
            ""
        ]
    
    def generate_drop_column_cleanup(self, change: SchemaChange) -> List[str]:
        """Generate SQL for column drop cleanup (optional)."""
        table = self._get_iceberg_table_name(change.table_name)
        column = change.column_name
        
        return [
            f"-- Column Drop Cleanup: {column}",
            f"-- Note: Debezium keeps the column in Iceberg, filling with NULL",
            f"-- This is optional cleanup if you want to remove it entirely",
            "",
            "-- ⚠️  WARNING: This will permanently delete the column and its data!",
            "-- Only run this after confirming the column is no longer needed",
            "",
            f"-- ALTER TABLE {table}",
            f"--   DROP COLUMN {column};",
            "",
            "-- Alternative: Leave column as-is for historical data preservation",
            ""
        ]
    
    def generate_migration_script(self) -> str:
        """Generate the complete Iceberg migration script."""
        lines = [
            "-- Iceberg Migration Script",
            f"-- Generated for: {self.analyzer.migration_file.name}",
            "-- Execute this in Spark SQL, Trino, or your Iceberg query engine",
            "",
            "-- ⚠️  IMPORTANT: Stop the Debezium server before running this script!",
            "-- ⚠️  Restart Debezium after completing the migration.",
            "",
            "-- ═══════════════════════════════════════════════════════════════",
            ""
        ]
        
        manual_changes = [c for c in self.analyzer.changes 
                         if c.status == ChangeStatus.MANUAL]
        
        if not manual_changes:
            lines.extend([
                "-- ✅ No manual migrations required!",
                "-- All changes can be handled automatically by Debezium-Iceberg",
                ""
            ])
            return '\n'.join(lines)
        
        for change in manual_changes:
            if change.change_type == ChangeType.RENAME_COLUMN:
                lines.extend(self.generate_rename_column_migration(change))
            
            elif change.change_type == ChangeType.ALTER_TYPE:
                lines.extend(self.generate_type_change_migration(change))
            
            # Add separator between changes
            lines.extend(["", "-- " + "─" * 60, ""])
        
        # Caution items (optional migrations)
        caution_changes = [c for c in self.analyzer.changes 
                          if c.status == ChangeStatus.CAUTION]
        
        if caution_changes:
            lines.extend([
                "",
                "-- ═══════════════════════════════════════════════════════════════",
                "-- OPTIONAL CLEANUP (Caution Items)",
                "-- ═══════════════════════════════════════════════════════════════",
                ""
            ])
            
            for change in caution_changes:
                if change.change_type == ChangeType.DROP_COLUMN:
                    lines.extend(self.generate_drop_column_cleanup(change))
        
        # Footer with instructions
        lines.extend([
            "",
            "-- ═══════════════════════════════════════════════════════════════",
            "-- MIGRATION STEPS:",
            "-- ═══════════════════════════════════════════════════════════════",
            "-- 1. Stop the Debezium server",
            "-- 2. Run the above SQL commands (uncomment and review each one)",
            "-- 3. Apply the Postgres migration to your source database",
            "-- 4. Restart the Debezium server",
            "-- 5. Verify new data flows correctly with updated schema",
            "-- 6. (Optional) Backfill data from _legacy columns",
            "-- 7. Update downstream dbt models if needed",
            ""
        ])
        
        return '\n'.join(lines)


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: python generate_iceberg_migration.py <migration_file.sql> [--output <file>]")
        print("\nExample:")
        print("  python generate_iceberg_migration.py migrations/002_rename_weight.sql")
        print("  python generate_iceberg_migration.py migrations/002_rename_weight.sql --output iceberg_migration_002.sql")
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
    
    # Generate Iceberg migration script
    generator = IcebergMigrationGenerator(analyzer)
    script = generator.generate_migration_script()
    
    # Output
    if output_file:
        output_file.write_text(script)
        print(f"✅ Iceberg migration script written to: {output_file}")
        print(f"\n📄 Review the script and apply it to your Iceberg catalog:")
        print(f"   {output_file}")
    else:
        print("\n" + "═" * 70)
        print(script)
        print("═" * 70)
    
    print()


if __name__ == '__main__':
    main()
