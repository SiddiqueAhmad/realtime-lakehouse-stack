#!/bin/bash
#
# Evaluate Schema Migrations
#
# This script scans the migrations directory and evaluates each SQL migration
# for compatibility with Debezium-Iceberg schema evolution.
#

set -e

# Configuration
MIGRATIONS_DIR="${MIGRATIONS_DIR:-./migrations}"
SKILL_DIR=".agent/skills/schema-evaluator"
ANALYZER_SCRIPT="$SKILL_DIR/scripts/analyze_migration.py"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Header
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📊 Schema Migration Evaluator"
echo "  Checking migrations for Debezium-Iceberg compatibility"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if migrations directory exists
if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo -e "${YELLOW}⚠️  Migrations directory not found: $MIGRATIONS_DIR${NC}"
    echo "   Creating migrations directory..."
    mkdir -p "$MIGRATIONS_DIR"
    echo "   ✅ Created $MIGRATIONS_DIR"
    echo ""
    echo "   Add your SQL migration files there with naming like:"
    echo "     001_add_customer_phone.sql"
    echo "     002_rename_product_weight.sql"
    echo ""
    exit 0
fi

# Check if analyzer script exists
if [ ! -f "$ANALYZER_SCRIPT" ]; then
    echo -e "${RED}❌ Error: Analyzer script not found: $ANALYZER_SCRIPT${NC}"
    echo "   Please ensure the schema-evaluator skill is properly installed."
    exit 1
fi

# Find all SQL files in migrations directory
migration_files=$(find "$MIGRATIONS_DIR" -name "*.sql" -type f | sort)

if [ -z "$migration_files" ]; then
    echo -e "${YELLOW}⚠️  No migration files found in $MIGRATIONS_DIR${NC}"
    echo ""
    echo "   Create migration files with naming like:"
    echo "     $MIGRATIONS_DIR/001_add_customer_phone.sql"
    echo ""
    exit 0
fi

# Count migrations
migration_count=$(echo "$migration_files" | wc -l | tr -d ' ')
echo "Found $migration_count migration file(s) to evaluate"
echo ""

# Track overall status
has_errors=0
has_warnings=0
manual_count=0
safe_count=0

# Evaluate each migration
for migration_file in $migration_files; do
    # Run the analyzer
    if python3 "$ANALYZER_SCRIPT" "$migration_file"; then
        safe_count=$((safe_count + 1))
    else
        exit_code=$?
        if [ $exit_code -eq 1 ]; then
            # Manual intervention required
            manual_count=$((manual_count + 1))
            has_errors=1
            
            echo ""
            echo -e "${YELLOW}💡 Generate migration scripts for downstream services:${NC}"
            echo "   Iceberg: python3 $SKILL_DIR/scripts/generate_iceberg_migration.py $migration_file"
            echo "   dbt:     python3 $SKILL_DIR/scripts/generate_dbt_migration.py $migration_file"
        else
            # Other error
            has_errors=1
        fi
    fi
    
    echo ""
done

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📊 Evaluation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Total migrations: $migration_count"
echo -e "  ${GREEN}✅ Safe migrations: $safe_count${NC}"
echo -e "  ${YELLOW}🚨 Require manual intervention: $manual_count${NC}"
echo ""

if [ $has_errors -eq 1 ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ❌ MANUAL INTERVENTION REQUIRED${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Some migrations require manual downstream updates."
    echo "  Use the script generators above to create migration scripts."
    echo ""
    exit 1
else
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✅ ALL MIGRATIONS ARE SAFE${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  All schema changes will be automatically handled"
    echo "  by Debezium-Iceberg. Safe to proceed!"
    echo ""
    exit 0
fi
