-- Example Migration: Incompatible Type Changes
-- Status: 🚨 MANUAL - Requires intervention
--
-- This migration demonstrates type changes that require manual intervention
-- because they are incompatible or could cause data loss.

-- Type narrowing (unsafe - data loss risk)
-- ALTER TABLE inventory.orders ALTER COLUMN quantity TYPE SMALLINT;  -- int -> smallint 🚨

-- Semantic type change (incompatible)
ALTER TABLE inventory.orders ALTER COLUMN order_date TYPE TIMESTAMP;  -- date -> timestamp 🚨

-- Precision reduction (unsafe - data loss risk)
-- ALTER TABLE inventory.products ALTER COLUMN weight TYPE DECIMAL(8,2);  -- decimal(10,2) -> decimal(8,2) 🚨

-- These changes will cause Debezium to fail with an error like:
-- "Cannot change column type: order_date: date -> timestamp"
--
-- Solution: Generate migration scripts:
--   python3 .agent/skills/schema-evaluator/scripts/generate_iceberg_migration.py \
--     examples/004_manual_type_changes.sql
