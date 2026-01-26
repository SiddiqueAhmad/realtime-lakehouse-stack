#!/bin/bash
# Migration 002 Verification Script
# Run this AFTER migration to verify everything is working correctly

set -e

echo "🔍 Migration 002 Verification Script"
echo "====================================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

# ──────────────────────────────────────────────────────────────
# CHECK 1: Debezium is running
# ──────────────────────────────────────────────────────────────

echo "📊 Check 1: Debezium Status"
if docker-compose ps debezium | grep -q "Up"; then
    echo -e "${GREEN}✅ PASS: Debezium is running${NC}"
    ((PASSED++))
else
    echo -e "${RED}❌ FAIL: Debezium is not running${NC}"
    echo "   Run: docker-compose start debezium"
    ((FAILED++))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 2: Debezium logs for errors
# ──────────────────────────────────────────────────────────────

echo "📊 Check 2: Debezium Errors"
ERROR_COUNT=$(docker-compose logs --tail=100 debezium 2>/dev/null | grep -i "error" | wc -l || echo 0)
if [ "$ERROR_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✅ PASS: No errors in Debezium logs${NC}"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠️  WARNING: Found $ERROR_COUNT error(s) in Debezium logs${NC}"
    echo "   Review logs: docker-compose logs debezium"
    ((FAILED++))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 3: Postgres schema
# ──────────────────────────────────────────────────────────────

echo "📊 Check 3: Postgres Schema"
echo "⚠️  MANUAL CHECK REQUIRED"
echo ""
echo "Run this in psql:"
echo "  \\d+ inventory.products"
echo ""
echo -e "Expected: Column ${GREEN}product_weight${NC} exists (NOT 'weight')"
read -p "Does product_weight column exist in Postgres? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}✅ PASS: Postgres schema updated${NC}"
    ((PASSED++))
else
    echo -e "${RED}❌ FAIL: Postgres schema not updated${NC}"
    ((FAILED++))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 4: Iceberg schema
# ──────────────────────────────────────────────────────────────

echo "📊 Check 4: Iceberg Schema"
echo "⚠️  MANUAL CHECK REQUIRED"
echo ""
echo "Run this in Trino/Spark:"
echo "  DESCRIBE iceberg.icebergdata.debeziumcdc_products;"
echo ""
echo -e "Expected: "
echo -e "  - ${GREEN}weight_legacy${NC} column exists (old data)"
echo -e "  - ${GREEN}product_weight${NC} column exists (new data)"
read -p "Do both columns exist in Iceberg? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}✅ PASS: Iceberg schema updated correctly${NC}"
    ((PASSED++))
else
    echo -e "${RED}❌ FAIL: Iceberg schema incorrect${NC}"
    ((FAILED++))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 5: Data flow test
# ──────────────────────────────────────────────────────────────

echo "📊 Check 5: Data Flow Test"
echo "⚠️  MANUAL CHECK REQUIRED"
echo ""
echo "1. Insert a test record in Postgres:"
echo "   INSERT INTO inventory.products (name, product_weight, price)"
echo "   VALUES ('Migration Test Product', 99.99, 19.99);"
echo ""
echo "2. Wait 5-10 seconds for CDC to sync"
echo ""
echo "3. Check in Trino/Spark:"
echo "   SELECT id, name, product_weight, weight_legacy"
echo "   FROM iceberg.icebergdata.debeziumcdc_products"
echo "   WHERE name = 'Migration Test Product';"
echo ""
echo "Expected:"
echo "  - product_weight = 99.99 (new data flows here)"
echo "  - weight_legacy = NULL (old column)"
echo ""
read -p "Does new data flow to product_weight column? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}✅ PASS: New data flows correctly${NC}"
    ((PASSED++))
else
    echo -e "${RED}❌ FAIL: Data not flowing correctly${NC}"
    echo "   Troubleshoot: Check Debezium connector status"
    ((FAILED++))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 6: Historical data accessibility
# ──────────────────────────────────────────────────────────────

echo "📊 Check 6: Historical Data"
echo "⚠️  MANUAL CHECK REQUIRED"
echo ""
echo "Run this in Trino/Spark:"
echo "  SELECT COUNT(*) as historical_count"
echo "  FROM iceberg.icebergdata.debeziumcdc_products"
echo "  WHERE weight_legacy IS NOT NULL"
echo "  AND product_weight IS NULL;"
echo ""
echo "This should return the count of historical records"
read -p "Can you access historical data via weight_legacy? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}✅ PASS: Historical data accessible${NC}"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠️  WARNING: Check if historical data exists${NC}"
    ((FAILED++))
fi
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 7: dbt models updated
# ──────────────────────────────────────────────────────────────

echo "📊 Check 7: dbt Models"
echo ""
echo "Search for COALESCE pattern in dbt models:"
cd dbt_project 2>/dev/null || cd .. || true
COALESCE_COUNT=$(grep -r "COALESCE.*product_weight.*weight_legacy" models/ 2>/dev/null | wc -l || echo 0)

if [ "$COALESCE_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✅ PASS: Found $COALESCE_COUNT model(s) using COALESCE pattern${NC}"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠️  WARNING: No COALESCE pattern found${NC}"
    echo "   Have you updated your dbt models yet?"
    read -p "Have dbt models been updated? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}✅ PASS: dbt models updated (manual confirmation)${NC}"
        ((PASSED++))
    else
        echo -e "${RED}❌ FAIL: Update dbt models using dbt_migration_002.sql${NC}"
        ((FAILED++))
    fi
fi
echo ""

# ──────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════"
echo "📊 VERIFICATION SUMMARY"
echo "═══════════════════════════════════════════════════"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL CHECKS PASSED!${NC}"
    echo ""
    echo "Migration 002 is SUCCESSFUL ✅"
    echo ""
    echo "Next steps:"
    echo "  1. Run dbt: dbt run --select +products"
    echo "  2. Run dbt tests: dbt test --select +products"
    echo "  3. Monitor production for 24-48 hours"
    echo "  4. Update BI dashboards if needed"
    echo ""
    exit 0
else
    echo -e "${RED}⚠️  SOME CHECKS FAILED${NC}"
    echo ""
    echo "Review failed checks above and take corrective action"
    echo "See: migrations/MIGRATION_002_SUMMARY.md for troubleshooting"
    echo ""
    exit 1
fi
