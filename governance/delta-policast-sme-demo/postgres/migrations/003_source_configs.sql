-- Add adapter-specific metadata bags without changing existing Delta rows.
-- Credentials remain deployment environment variables, not database config.
BEGIN;
SELECT pg_advisory_xact_lock(74014, 1);
CREATE TABLE IF NOT EXISTS governance.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE governance.data_sources
    ADD COLUMN IF NOT EXISTS config jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE governance.tables
    ADD COLUMN IF NOT EXISTS config jsonb NOT NULL DEFAULT '{}'::jsonb;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname='data_sources_config_object'
          AND conrelid='governance.data_sources'::regclass
    ) THEN
        ALTER TABLE governance.data_sources
            ADD CONSTRAINT data_sources_config_object
            CHECK (jsonb_typeof(config)='object');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname='tables_config_object'
          AND conrelid='governance.tables'::regclass
    ) THEN
        ALTER TABLE governance.tables
            ADD CONSTRAINT tables_config_object
            CHECK (jsonb_typeof(config)='object');
    END IF;
END;
$$;
INSERT INTO governance.schema_migrations(version)
VALUES ('003_source_configs') ON CONFLICT DO NOTHING;
COMMIT;
