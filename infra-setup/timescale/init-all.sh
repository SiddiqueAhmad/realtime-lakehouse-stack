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

# 2. Create the 'ehr' database for Debezium (synthetic healthcare/EHR data)
echo "🔧 Creating EHR database..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE ehr;
EOSQL
echo "✅ EHR database created."

# 3. Create the Debezium replication user (roles are global)
echo "🔧 Creating Debezium user..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE debezium_user WITH REPLICATION LOGIN PASSWORD 'debezium_pass';
EOSQL
echo "✅ Debezium user created."

# 4. Grant connect permission to the new 'ehr' database
echo "🔧 Granting connect permission to EHR DB..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    GRANT CONNECT ON DATABASE ehr TO debezium_user;
EOSQL
echo "✅ Connect permission granted."

# 5. Connect to the 'ehr' database and run the healthcare.sql script
echo "🔧 Populating EHR database schema and synthetic data..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "ehr" < /docker-entrypoint-initdb.d/healthcare.sql
echo "✅ EHR database populated."

# 6. NOW, connect to the 'ehr' database again to grant permissions and create publication
echo "🔧 Setting up permissions and publication in EHR DB..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "ehr" <<-EOSQL
    -- Grant the Debezium user permissions for the ehr schema
    GRANT USAGE ON SCHEMA ehr TO debezium_user;
    GRANT SELECT ON ALL TABLES IN SCHEMA ehr TO debezium_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA ehr
    GRANT SELECT ON TABLES TO debezium_user;

    -- Create the publication for Debezium
    -- This tells Postgres *which* tables to publish changes for.
    CREATE PUBLICATION dbz_publication FOR ALL TABLES;
EOSQL
echo "✅ Permissions and publication set up."

# 7. enable extension pgvectorscale (used later for embeddings on de-identified data)
echo "🔧 Installing pgvectorscale extension in ehr"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname ehr  <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
EOSQL
echo "✅ pgvectorscale extension installed in ehr."


echo "🎉 Database initialization complete!"
