#!/bin/bash
# Quick Migration Execution Script for Migration 002
# This script helps you execute the migration step-by-step
# Run each step manually (uncomment as you go)

set -e  # Exit on error

echo "🚀 Migration 002: Rename weight → product_weight"
echo "=================================================="
echo ""

# ──────────────────────────────────────────────────────────────
# PHASE 1: STOP DEBEZIUM
# ──────────────────────────────────────────────────────────────

read -p "Step 1: Stop Debezium? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🛑 Stopping Debezium..."
    docker-compose stop debezium
    echo "✅ Debezium stopped"
fi

# ──────────────────────────────────────────────────────────────
# PHASE 2: APPLY ICEBERG MIGRATION
# ──────────────────────────────────────────────────────────────

echo ""
echo "⚠️  MANUAL STEP: Apply Iceberg migration"
echo "Execute this in Trino/Spark:"
echo ""
cat migrations/iceberg_migration_002.sql | grep "ALTER TABLE" | grep -v "^--"
echo ""
read -p "Have you applied the Iceberg migration? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Migration aborted. Apply Iceberg migration first."
    exit 1
fi

# ──────────────────────────────────────────────────────────────
# PHASE 3: VERIFY ICEBERG SCHEMA
# ──────────────────────────────────────────────────────────────

echo ""
echo "⚠️  MANUAL STEP: Verify Iceberg schema"
echo "Run in Trino/Spark:"
echo "  DESCRIBE iceberg.icebergdata.debeziumcdc_products;"
echo ""
echo "Expected: 'weight_legacy' column exists"
echo ""
read -p "Schema verified? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Migration aborted. Verify Iceberg schema first."
    exit 1
fi

# ──────────────────────────────────────────────────────────────
# PHASE 4: APPLY POSTGRES MIGRATION
# ──────────────────────────────────────────────────────────────

echo ""
read -p "Step 2: Apply Postgres migration? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "📝 Applying Postgres migration..."
    
    # Uncomment and modify these lines with your actual connection details
    # psql -h localhost -U testuser -d inventory -f migrations/002_rename_weight_column.sql
    
    echo "⚠️  Execute manually with your credentials:"
    echo "  psql -h YOUR_HOST -U YOUR_USER -d inventory -f migrations/002_rename_weight_column.sql"
    echo ""
    read -p "Postgres migration applied? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Migration aborted."
        exit 1
    fi
fi

# ──────────────────────────────────────────────────────────────
# PHASE 5: RESTART DEBEZIUM
# ──────────────────────────────────────────────────────────────

echo ""
read -p "Step 3: Restart Debezium? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "▶️  Restarting Debezium..."
    docker-compose start debezium
    echo "✅ Debezium started"
    echo ""
    echo "🔍 Checking Debezium logs..."
    sleep 3
    docker-compose logs --tail=50 debezium
fi

# ──────────────────────────────────────────────────────────────
# PHASE 6: VERIFY DATA FLOW
# ──────────────────────────────────────────────────────────────

echo ""
echo "⚠️  MANUAL STEP: Verify data flow"
echo "1. Insert a test record in Postgres:"
echo "   INSERT INTO inventory.products (name, product_weight, price)"
echo "   VALUES ('Test Product', 5.5, 99.99);"
echo ""
echo "2. Check it appears in Iceberg (Trino/Spark):"
echo "   SELECT id, name, product_weight, weight_legacy"
echo "   FROM iceberg.icebergdata.debeziumcdc_products"
echo "   WHERE name = 'Test Product';"
echo ""
read -p "Data flow verified? (y/n) " -n 1 -r
echo

# ──────────────────────────────────────────────────────────────
# PHASE 7: UPDATE DBT MODELS
# ──────────────────────────────────────────────────────────────

echo ""
echo "📊 Next Steps:"
echo "1. Update dbt models (see migrations/dbt_migration_002.sql)"
echo "2. Run: dbt run --select +products"
echo "3. Run: dbt test --select +products"
echo ""
echo "✅ Migration complete!"
echo "📋 Full details: migrations/MIGRATION_002_SUMMARY.md"
