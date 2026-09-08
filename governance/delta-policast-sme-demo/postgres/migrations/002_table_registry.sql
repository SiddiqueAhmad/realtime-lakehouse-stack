-- Add a generic source/table registry without rewriting any identities,
-- policies, bindings, or object-storage files. Safe to reapply.
BEGIN;
SELECT pg_advisory_xact_lock(74014, 1);
CREATE TABLE IF NOT EXISTS governance.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema='governance' AND table_name='principals' AND column_name='attributes') THEN
        RAISE EXCEPTION 'Run 001_dynamic_governance before 002_table_registry';
    END IF;
END;
$$;
CREATE TABLE IF NOT EXISTS governance.data_sources (
    source_key text PRIMARY KEY,
    kind text NOT NULL,
    enabled boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS governance.tables (
    table_key text PRIMARY KEY,
    source_key text NOT NULL REFERENCES governance.data_sources(source_key),
    logical_name text NOT NULL UNIQUE CHECK (logical_name ~ '^[a-z_][a-z0-9_]*$'),
    location text NOT NULL CHECK (length(trim(location)) > 0),
    enabled boolean NOT NULL DEFAULT true
);
INSERT INTO governance.schema_migrations(version) VALUES ('002_table_registry') ON CONFLICT DO NOTHING;
COMMIT;
