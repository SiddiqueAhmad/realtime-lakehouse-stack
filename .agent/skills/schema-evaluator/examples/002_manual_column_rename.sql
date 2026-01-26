-- Example Migration: Column Rename
-- Status: 🚨 MANUAL - Requires intervention
--
-- This migration demonstrates a column rename, which Debezium treats as
-- a DROP + ADD operation. The old column's data will be lost for new records
-- unless you perform a manual Iceberg table migration first.

-- Rename weight column to be more descriptive
ALTER TABLE inventory.products RENAME COLUMN weight TO product_weight;

-- This will cause:
-- 1. Old column 'weight' will still exist in Iceberg (with NULLs for new records)
-- 2. New column 'product_weight' will be created automatically
-- 3. Data in 'weight' column will not automatically migrate to 'product_weight'
--
-- Solution: Generate migration scripts:
--   python3 .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py \
--     examples/002_manual_column_rename.sql
