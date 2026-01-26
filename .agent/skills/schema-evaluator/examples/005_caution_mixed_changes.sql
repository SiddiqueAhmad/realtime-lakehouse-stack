-- Example Migration: Mixed Safe and Caution Changes
-- Status: ⚠️ CAUTION - Review recommended
--
-- This migration demonstrates changes that work automatically but may have
-- unintended consequences that you should be aware of.

-- Drop column (column persists in Iceberg with NULLs)
ALTER TABLE inventory.products DROP COLUMN description;  -- ⚠️ Column remains, new records = NULL

-- Add NOT NULL constraint (not enforced in Iceberg)
ALTER TABLE inventory.customers ALTER COLUMN email SET NOT NULL;  -- ⚠️ Not enforced downstream

-- Add default value (only affects new Postgres inserts)
ALTER TABLE inventory.products ALTER COLUMN category SET DEFAULT 'GENERAL';  -- ⚠️ Postgres only

-- Add constraint (not replicated to Iceberg)
ALTER TABLE inventory.orders ADD CONSTRAINT check_positive_quantity CHECK (quantity > 0);  -- ⚠️ Not enforced

-- These changes work but you should understand their limitations:
-- - Dropped columns: Still exist in Iceberg for historical data
-- - Constraints: Only enforced in Postgres, not in Iceberg
-- - Defaults: Applied in Postgres before CDC capture, visible in Iceberg data
