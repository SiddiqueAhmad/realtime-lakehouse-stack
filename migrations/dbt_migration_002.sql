-- dbt Model Migration Guide
-- Generated for: 002_rename_weight_column.sql

-- This guide helps you update your dbt models to handle upstream
-- schema changes from Postgres → Debezium → Iceberg

-- ═══════════════════════════════════════════════════════════════

-- dbt Model Update: Column Rename (weight → product_weight)
-- Table: inventory.products

-- Update your dbt SELECT to use COALESCE for backward compatibility:
COALESCE(product_weight, weight_legacy) AS product_weight,

-- This allows the model to work with both old and new data
-- Old records: {old_col}_legacy has data, {new_col} is NULL
-- New records: {new_col} has data, {old_col}_legacy is NULL

-- Full example for a dbt model using debeziumcdc_products:
-- SELECT
--   order_id,
--   product_id,
--   COALESCE(product_weight, weight_legacy) AS product_weight,
--   quantity
-- FROM {{ source('iceberg', 'debeziumcdc_products') }}


-- ────────────────────────────────────────────────────────────


-- ═══════════════════════════════════════════════════════════════
-- SCHEMA.YML UPDATES
-- ═══════════════════════════════════════════════════════════════

# Update your dbt schema.yml file
# Location: models/schema.yml or models/<layer>/schema.yml

version: 2

models:
  - name: your_model_using_products
    description: "Update description if schema changed significantly"
    columns:
      - name: product_weight
        description: "Renamed from weight → product_weight"


-- ═══════════════════════════════════════════════════════════════
-- RECOMMENDED WORKFLOW:
-- ═══════════════════════════════════════════════════════════════
-- 1. Review the suggested SQL updates above
-- 2. Update your dbt model SQL files (models/silver/*.sql, etc.)
-- 3. Update schema.yml with new/renamed columns
-- 4. Test locally: dbt run --select <affected_models>
-- 5. Run tests: dbt test --select <affected_models>
-- 6. If using incremental models, consider: dbt run --full-refresh
-- 7. Deploy to production after validation
