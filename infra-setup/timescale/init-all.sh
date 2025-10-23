#!/bin/bash
set -e

# This script is run by the postgres user.
# The 'psql' command will connect as the POSTGRES_USER (testuser)
# to the POSTGRES_DB (test).

echo "🚀 Starting database initialization..."

# 1. Create Metabase database
echo "🔧 Creating Metabase database..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE metabaseappdb;
    GRANT ALL PRIVILEGES ON DATABASE metabaseappdb TO testuser;
EOSQL
echo "✅ Metabase database created."

# 2. Create the 'inventory' database for Debezium
echo "🔧 Creating Inventory database..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE inventory;
EOSQL
echo "✅ Inventory database created."

# 3. Create the Debezium replication user (roles are global)
echo "🔧 Creating Debezium user..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE debezium_user WITH REPLICATION LOGIN PASSWORD 'debezium_pass';
EOSQL
echo "✅ Debezium user created."

# 4. Grant connect permission to the new 'inventory' database
echo "🔧 Granting connect permission to Inventory DB..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    GRANT CONNECT ON DATABASE inventory TO debezium_user;
EOSQL
echo "✅ Connect permission granted."

# 5. Connect to the 'inventory' database and run the inventory.sql script
echo "🔧 Populating Inventory database schema and data..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "inventory" < /docker-entrypoint-initdb.d/inventory.sql
echo "✅ Inventory database populated."

# 6. NOW, connect to the 'inventory' database again to grant permissions and create publication
echo "🔧 Setting up permissions and publication in Inventory DB..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "inventory" <<-EOSQL
    -- Grant the Debezium user permissions for the inventory schema
    GRANT USAGE ON SCHEMA inventory TO debezium_user;
    GRANT SELECT ON ALL TABLES IN SCHEMA inventory TO debezium_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA inventory
    GRANT SELECT ON TABLES TO debezium_user;

    -- Create the publication for Debezium
    -- This tells Postgres *which* tables to publish changes for.
    CREATE PUBLICATION dbz_publication FOR ALL TABLES;
EOSQL
echo "✅ Permissions and publication set up."

# 7. enable extension pgvectorscale
echo "🔧 Installing pgvectorscale extension in inventory"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname inventory  <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
EOSQL
echo "✅ pgvectorscale extension installed in inventory."


echo "🎉 Database initialization complete!"
