-- Add audit persistence for explicit control-plane changes made through the UI.
-- AI drafts are never persisted automatically; only approved writes reach this table.
BEGIN;
SELECT pg_advisory_xact_lock(74014, 1);
CREATE TABLE IF NOT EXISTS governance.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS governance.control_plane_audit (
    audit_id bigserial PRIMARY KEY,
    entity_type text NOT NULL,
    entity_key text NOT NULL,
    action text NOT NULL,
    actor text NOT NULL,
    source text NOT NULL DEFAULT 'ui',
    before_state jsonb,
    after_state jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (length(trim(entity_type)) > 0),
    CHECK (length(trim(entity_key)) > 0),
    CHECK (length(trim(action)) > 0),
    CHECK (length(trim(actor)) > 0),
    CHECK (length(trim(source)) > 0),
    CHECK (before_state IS NULL OR jsonb_typeof(before_state) = 'object'),
    CHECK (jsonb_typeof(after_state) = 'object')
);
CREATE INDEX IF NOT EXISTS idx_control_plane_audit_entity
    ON governance.control_plane_audit(entity_type, entity_key, audit_id DESC);
INSERT INTO governance.schema_migrations(version)
VALUES ('004_control_plane_ui') ON CONFLICT DO NOTHING;
COMMIT;
