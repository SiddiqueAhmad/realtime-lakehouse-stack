-- Example Migration: Safe Type Expansions
-- Status: ✅ SAFE - Automatic handling
--
-- This migration demonstrates safe data type expansions that  will
-- be automatically handled by Debezium-Iceberg without data loss.

-- Expand integer types (safe expansions)
ALTER TABLE inventory.products ALTER COLUMN id TYPE BIGINT;  -- int -> bigint ✅

-- Expand to floating point (safe for numeric data)
ALTER TABLE inventory.orders ALTER COLUMN quantity TYPE BIGINT;  -- int -> bigint ✅

-- Increase string length (safe expansion)
ALTER TABLE inventory.customers ALTER COLUMN first_name TYPE VARCHAR(500);  -- varchar(255) -> varchar(500) ✅
ALTER TABLE inventory.customers ALTER COLUMN last_name TYPE VARCHAR(500);

-- Increase numeric precision (safe if done correctly)
-- ALTER TABLE inventory.products ALTER COLUMN weight TYPE DECIMAL(12,4);  -- decimal(10,2) -> decimal(12,4) ✅
