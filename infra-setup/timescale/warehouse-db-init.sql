-- Creates the `warehouse` Postgres database: home for (a) the raw_cdc
-- schema Debezium's JDBC sink writes into (the append-only CDC event log -
-- see debezium-server-conf/application.properties and
-- warehouse/macros/cdc_reliability.sql), and (b) the DuckLake catalog
-- metadata tables the `ducklake` DuckDB extension manages automatically once
-- attached (see warehouse/profiles.yml) - both live in the same Postgres
-- server as the `ehr` OLTP source and `metabaseappdb`, just a separate
-- database, so no extra infra is needed to run this stack.
--
-- Runs as its own compose service (warehouse-db-init) rather than folded
-- into timescale/init-all.sh, which only runs on a brand-new data
-- directory - this needs to succeed on every `docker compose up`, including
-- a restart against an existing volume.

SELECT 'CREATE DATABASE warehouse'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'warehouse')\gexec

\connect warehouse

CREATE SCHEMA IF NOT EXISTS raw_cdc;

-- The JDBC sink and dbt-duckdb's postgres attach both connect as testuser
-- (the same broad dev credential used everywhere else in this repo's local
-- stack - see README's threat-model note) so no additional role is
-- created here.
GRANT ALL ON SCHEMA raw_cdc TO testuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_cdc GRANT ALL ON TABLES TO testuser;
