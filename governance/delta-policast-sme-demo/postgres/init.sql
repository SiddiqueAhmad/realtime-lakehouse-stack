CREATE SCHEMA IF NOT EXISTS governance;

-- Principals have a small stable envelope plus an open-ended string attribute bag.
-- Policies can reference any key in `attributes` as `principal.<key>` without a
-- Rust code change. Reserved identity fields (`role`, `principal_id`, `name`) are
-- supplied by the query service and cannot be spoofed by JSON attributes.
CREATE TABLE IF NOT EXISTS governance.principals (
    principal_key text PRIMARY KEY,
    role text NOT NULL,
    display_name text,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (jsonb_typeof(attributes) = 'object')
);

INSERT INTO governance.principals(principal_key, role, display_name, attributes)
VALUES
    ('admin',     'admin',     'Platform Admin',      '{}'::jsonb),
    ('analyst',   'analyst',   'Healthcare Analyst', '{"region":"us-east","department":"analytics","company_id":"demo-co"}'::jsonb),
    ('physician', 'physician', 'Dr. Smith',           '{"department":"clinical","company_id":"demo-co"}'::jsonb)
ON CONFLICT (principal_key) DO UPDATE SET
    role = EXCLUDED.role,
    display_name = EXCLUDED.display_name,
    attributes = EXCLUDED.attributes;

CREATE TABLE IF NOT EXISTS governance.policies (
    policy_key text PRIMARY KEY,
    cedar text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Policy logic is independent of assignment. No @roles annotation is needed:
-- policy_bindings below decides which principals receive which policies.
INSERT INTO governance.policies(policy_key, cedar) VALUES
('row_filter_region', $cedar$
@id("row_filter_region")
@filter_type("row_filter")
@target_table("patients")
permit (
    principal,
    action == Action::"query",
    resource
)
when {
    resource.region == principal.region
};
$cedar$),

('row_filter_physician', $cedar$
@id("row_filter_physician")
@filter_type("row_filter")
@target_table("patients")
permit (
    principal,
    action == Action::"query",
    resource
)
when {
    resource.treating_physician == principal.name
};
$cedar$),

('mask_ssn', $cedar$
@id("mask_ssn")
@filter_type("column_mask")
@target_table("patients")
@column("ssn")
forbid (
    principal,
    action == Action::"query",
    resource
)
unless {
    principal.role == "admin" || principal.role == "physician"
};
$cedar$),

('mask_diagnosis', $cedar$
@id("mask_diagnosis")
@filter_type("column_mask")
@target_table("patients")
@column("diagnosis")
forbid (
    principal,
    action == Action::"query",
    resource
)
unless {
    principal.role == "admin" || principal.role == "physician"
};
$cedar$),

('deny_legal_hold', $cedar$
@id("deny_legal_hold")
@filter_type("deny_override")
@target_table("patients")
forbid (
    principal,
    action,
    resource
)
when {
    resource.legal_hold == true
}
unless {
    principal.role == "legal"
};
$cedar$)
ON CONFLICT (policy_key) DO UPDATE SET
    cedar = EXCLUDED.cedar,
    enabled = true,
    updated_at = now();

-- Assignment is data, not policy source. Supported selectors in this POC:
--   *                    global binding
--   role:<role>          all principals with a role
--   principal:<key>      one principal
-- `target` is the logical governed table name or `*`.
CREATE TABLE IF NOT EXISTS governance.policy_bindings (
    binding_id text PRIMARY KEY,
    policy_key text NOT NULL REFERENCES governance.policies(policy_key) ON DELETE CASCADE,
    target text NOT NULL DEFAULT '*',
    principal_selector text NOT NULL,
    precedence integer NOT NULL DEFAULT 0,
    enabled boolean NOT NULL DEFAULT true,
    CHECK (
        principal_selector = '*'
        OR principal_selector LIKE 'role:%'
        OR principal_selector LIKE 'principal:%'
    )
);

INSERT INTO governance.policy_bindings(
    binding_id, policy_key, target, principal_selector, precedence, enabled
)
VALUES
    ('bind_region_analyst',       'row_filter_region',    'patients', 'role:analyst',    100, true),
    ('bind_physician_own_rows',   'row_filter_physician', 'patients', 'role:physician',  100, true),
    ('bind_mask_ssn_global',      'mask_ssn',             'patients', '*',                10, true),
    ('bind_mask_diagnosis_global','mask_diagnosis',       'patients', '*',                10, true),
    ('bind_legal_hold_global',    'deny_legal_hold',      'patients', '*',               100, true)
ON CONFLICT (binding_id) DO UPDATE SET
    policy_key = EXCLUDED.policy_key,
    target = EXCLUDED.target,
    principal_selector = EXCLUDED.principal_selector,
    precedence = EXCLUDED.precedence,
    enabled = EXCLUDED.enabled;
