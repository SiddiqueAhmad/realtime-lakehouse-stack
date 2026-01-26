-- Iceberg Migration Script
-- Generated for: 002_rename_weight_column.sql
-- Execute this in Spark SQL, Trino, or your Iceberg query engine

-- ⚠️  IMPORTANT: Stop the Debezium server before running this script!
-- ⚠️  Restart Debezium after completing the migration.

-- ═══════════════════════════════════════════════════════════════

-- Column Rename Migration: weight → product_weight;
-- Strategy: Rename old column to preserve historical data
-- New column will be auto-created by Debezium

ALTER TABLE iceberg.icebergdata.debeziumcdc_products
  RENAME COLUMN weight TO weight_legacy;

-- After restarting Debezium, the new column will be created automatically
-- Optional: Backfill data from legacy column to new column:
-- UPDATE iceberg.icebergdata.debeziumcdc_products
--   SET product_weight = weight_legacy
--   WHERE product_weight IS NULL;


-- ────────────────────────────────────────────────────────────


-- ═══════════════════════════════════════════════════════════════
-- MIGRATION STEPS:
-- ═══════════════════════════════════════════════════════════════
-- 1. Stop the Debezium server
-- 2. Run the above SQL commands (uncomment and review each one)
-- 3. Apply the Postgres migration to your source database
-- 4. Restart the Debezium server
-- 5. Verify new data flows correctly with updated schema
-- 6. (Optional) Backfill data from _legacy columns
-- 7. Update downstream dbt models if needed
