#!/usr/bin/env python3
"""
Migration Analyzer - Parses SQL migration files and assesses schema change compatibility.

This script analyzes Postgres ALTER TABLE statements and determines whether
they can be automatically handled by Debezium-Iceberg or require manual intervention.
"""

import re
import sys
from pathlib import Path
from typing import List, Dict, Tuple, Optional
from dataclasses import dataclass

# Import schema rules
from schema_rules import (
    ChangeStatus, ChangeType, evaluate_change, 
    check_debezium_config, normalize_type
)


@dataclass
class SchemaChange:
    """Represents a single schema change operation."""
    change_type: ChangeType
    table_name: str
    column_name: Optional[str]
    from_type: Optional[str]
    to_type: Optional[str]
    sql_statement: str
    line_number: int
    status: ChangeStatus
    explanation: str


class MigrationAnalyzer:
    """Analyzes SQL migration files for schema compatibility."""
    
    # Regex patterns for SQL parsing
    PATTERNS = {
        'add_column': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+ADD\s+COLUMN\s+(\S+)\s+(\S+)',
            re.IGNORECASE
        ),
        'drop_column': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+DROP\s+COLUMN\s+(\S+)',
            re.IGNORECASE
        ),
        'rename_column': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+RENAME\s+COLUMN\s+(\S+)\s+TO\s+(\S+)',
            re.IGNORECASE
        ),
        'alter_type': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+ALTER\s+COLUMN\s+(\S+)\s+TYPE\s+([^;,\s]+)',
            re.IGNORECASE
        ),
        'alter_nullable': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+ALTER\s+COLUMN\s+(\S+)\s+(SET|DROP)\s+NOT\s+NULL',
            re.IGNORECASE
        ),
        'add_constraint': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+ADD\s+CONSTRAINT',
            re.IGNORECASE
        ),
        'drop_constraint': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+DROP\s+CONSTRAINT',
            re.IGNORECASE
        ),
        'alter_default': re.compile(
            r'ALTER\s+TABLE\s+(\S+)\s+ALTER\s+COLUMN\s+(\S+)\s+(SET|DROP)\s+DEFAULT',
            re.IGNORECASE
        ),
    }
    
    def __init__(self, migration_file: Path):
        """
        Initialize analyzer with a migration file.
        
        Args:
            migration_file: Path to SQL migration file
        """
        self.migration_file = migration_file
        self.changes: List[SchemaChange] = []
        self.warnings: List[str] = []
    
    def parse_sql_file(self) -> None:
        """Parse the SQL file and extract schema changes."""
        try:
            with open(self.migration_file, 'r') as f:
                content = f.read()
        except FileNotFoundError:
            raise ValueError(f"Migration file not found: {self.migration_file}")
        
        # Split into individual statements (basic split on semicolons)
        # Note: This is a simplified parser; production use might need a proper SQL parser
        lines = content.split('\n')
        
        for line_num, line in enumerate(lines, start=1):
            line = line.strip()
            
            # Skip comments and empty lines
            if not line or line.startswith('--') or line.startswith('/*'):
                continue
            
            # Check each pattern
            for pattern_name, pattern in self.PATTERNS.items():
                match = pattern.search(line)
                if match:
                    self._process_match(pattern_name, match, line, line_num)
                    break
    
    def _process_match(self, pattern_name: str, match, sql: str, line_num: int) -> None:
        """Process a regex match and create a SchemaChange."""
        
        if pattern_name == 'add_column':
            table, column, col_type = match.groups()
            change_type = ChangeType.ADD_COLUMN
            status, explanation = evaluate_change(
                change_type,
                column_name=column,
                to_type=col_type
            )
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=column,
                from_type=None,
                to_type=col_type,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
        
        elif pattern_name == 'drop_column':
            table, column = match.groups()
            change_type = ChangeType.DROP_COLUMN
            status, explanation = evaluate_change(change_type, column_name=column)
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=column,
                from_type=None,
                to_type=None,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
        
        elif pattern_name == 'rename_column':
            table, old_col, new_col = match.groups()
            change_type = ChangeType.RENAME_COLUMN
            status, explanation = evaluate_change(
                change_type,
                column_name=old_col,
                new_column_name=new_col
            )
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=f"{old_col} → {new_col}",
                from_type=None,
                to_type=None,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
        
        elif pattern_name == 'alter_type':
            table, column, new_type = match.groups()
            change_type = ChangeType.ALTER_TYPE
            # Note: We don't know the FROM type without introspecting the database
            # For now, we'll mark it as requiring manual review
            status, explanation = evaluate_change(
                change_type,
                column_name=column,
                from_type='unknown',
                to_type=new_type
            )
            # Override status to be conservative since we don't know the from_type
            if status == ChangeStatus.SAFE:
                status = ChangeStatus.MANUAL
                explanation = (f"Type change detected: → {new_type}. "
                              "Cannot verify safety without knowing current type. "
                              "Manual review required.")
            
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=column,
                from_type='unknown',
                to_type=new_type,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
        
        elif pattern_name == 'alter_nullable':
            table, column, action = match.groups()
            change_type = ChangeType.ALTER_NULLABLE
            status, explanation = evaluate_change(change_type, column_name=column)
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=column,
                from_type=None,
                to_type=None,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
        
        elif pattern_name in ('add_constraint', 'drop_constraint'):
            table = match.group(1)
            change_type = (ChangeType.ADD_CONSTRAINT if pattern_name == 'add_constraint' 
                          else ChangeType.DROP_CONSTRAINT)
            status, explanation = evaluate_change(change_type, table_name=table)
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=None,
                from_type=None,
                to_type=None,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
        
        elif pattern_name == 'alter_default':
            table, column, action = match.groups()
            change_type = ChangeType.ALTER_DEFAULT
            status, explanation = evaluate_change(change_type, column_name=column)
            self.changes.append(SchemaChange(
                change_type=change_type,
                table_name=table,
                column_name=column,
                from_type=None,
                to_type=None,
                sql_statement=sql,
                line_number=line_num,
                status=status,
                explanation=explanation
            ))
    
    def get_summary(self) -> Dict[str, int]:
        """Get a summary count of change statuses."""
        summary = {
            'safe': 0,
            'caution': 0,
            'manual': 0
        }
        
        for change in self.changes:
            summary[change.status.value] += 1
        
        return summary
    
    def has_blocking_changes(self) -> bool:
        """Check if any changes require manual intervention."""
        return any(c.status == ChangeStatus.MANUAL for c in self.changes)
    
    def print_report(self, verbose: bool = True) -> None:
        """Print a formatted report of the analysis."""
        
        # Header
        print(f"\n📋 Evaluating migration: {self.migration_file.name}")
        print("━" * 60)
        
        if not self.changes:
            print("\n⚠️  No schema changes detected in this migration file.")
            print("   (Only ALTER TABLE statements are analyzed)")
            return
        
        # Status icons
        icons = {
            ChangeStatus.SAFE: "✅",
            ChangeStatus.CAUTION: "⚠️ ",
            ChangeStatus.MANUAL: "🚨"
        }
        
        # Print each change
        for change in self.changes:
            icon = icons[change.status]
            status_text = change.status.value.upper()
            
            print(f"\n  {icon} {status_text}: {change.sql_statement[:80]}")
            
            if verbose:
                if change.column_name:
                    print(f"     Table: {change.table_name}, Column: {change.column_name}")
                else:
                    print(f"     Table: {change.table_name}")
                
                print(f"     → {change.explanation}")
        
        # Summary
        summary = self.get_summary()
        print(f"\n📊 Summary: {len(self.changes)} change(s) detected")
        print(f"  ✅ Safe (automatic): {summary['safe']}")
        print(f"  ⚠️  Caution (review): {summary['caution']}")
        print(f"  🚨 Manual (intervention): {summary['manual']}")
        
        # Overall assessment
        print()
        if self.has_blocking_changes():
            print("🚨 MANUAL INTERVENTION REQUIRED")
            print("   This migration contains changes that Debezium-Iceberg cannot")
            print("   automatically handle. Generate migration scripts using:")
            print(f"   python .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py {self.migration_file}")
        elif summary['caution'] > 0:
            print("⚠️  CAUTION RECOMMENDED")
            print("   This migration will work but may have unintended side effects.")
            print("   Please review the warnings above carefully.")
        else:
            print("✅ Migration can be applied safely")
            print("   All changes will be automatically handled by Debezium-Iceberg")
        
        print()


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: python analyze_migration.py <migration_file.sql>")
        print("\nExample:")
        print("  python analyze_migration.py migrations/001_add_customer_phone.sql")
        sys.exit(1)
    
    migration_file = Path(sys.argv[1])
    
    if not migration_file.exists():
        print(f"❌ Error: Migration file not found: {migration_file}")
        sys.exit(1)
    
    # Check for verbose flag
    verbose = '--verbose' in sys.argv or '-v' in sys.argv
    
    # Analyze the migration
    analyzer = MigrationAnalyzer(migration_file)
    analyzer.parse_sql_file()
    analyzer.print_report(verbose=verbose)
    
    # Exit with error code if manual intervention required
    if analyzer.has_blocking_changes():
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
