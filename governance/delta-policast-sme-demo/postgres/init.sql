-- Domain-neutral control-plane schema. No principals, policies or business
-- tables are seeded by database initialization. Use fixtures separately.
CREATE SCHEMA IF NOT EXISTS governance;
CREATE TABLE IF NOT EXISTS governance.principals (
    principal_key text PRIMARY KEY,
    role text NOT NULL,
    display_name text,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (jsonb_typeof(attributes) = 'object')
);
CREATE TABLE IF NOT EXISTS governance.policies (
    policy_key text PRIMARY KEY,
    cedar text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS governance.policy_bindings (
    binding_id text PRIMARY KEY,
    policy_key text NOT NULL REFERENCES governance.policies(policy_key) ON DELETE CASCADE,
    target text NOT NULL DEFAULT '*',
    principal_selector text NOT NULL,
    precedence integer NOT NULL DEFAULT 0,
    enabled boolean NOT NULL DEFAULT true,
    CHECK (principal_selector = '*' OR principal_selector LIKE 'role:%' OR principal_selector LIKE 'principal:%')
);
