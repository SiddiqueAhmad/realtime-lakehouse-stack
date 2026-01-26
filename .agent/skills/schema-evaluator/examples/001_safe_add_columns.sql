-- Example Migration: Adding New Columns
-- Status: ✅ SAFE - Automatic handling by Debezium-Iceberg
-- 
-- This migration demonstrates adding new columns to an existing table.
-- Debezium-Iceberg will automatically add these columns to the Iceberg table
-- when allow-field-addition=true (which is set in application.properties).

-- Add phone tracking to customers
ALTER TABLE inventory.customers ADD COLUMN phone VARCHAR(20);
ALTER TABLE inventory.customers ADD COLUMN phone_verified BOOLEAN DEFAULT FALSE;
ALTER TABLE inventory.customers ADD COLUMN phone_added_date DATE DEFAULT CURRENT_DATE;

-- Add category to products
ALTER TABLE inventory.products ADD COLUMN category VARCHAR(50);
ALTER TABLE inventory.products ADD COLUMN is_active BOOLEAN DEFAULT TRUE;
