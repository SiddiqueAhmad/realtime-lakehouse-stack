CREATE SCHEMA IF NOT EXISTS governance;

CREATE TABLE IF NOT EXISTS governance.principals (
    principal_key text PRIMARY KEY,
    role text NOT NULL,
    region text,
    display_name text
);

INSERT INTO governance.principals(principal_key, role, region, display_name)
VALUES
    ('admin',     'admin',      NULL,      'Platform Admin'),
    ('analyst',   'analyst',    'us-east', 'Healthcare Analyst'),
    ('physician', 'physician',  NULL,      'Dr. Smith')
ON CONFLICT (principal_key) DO UPDATE SET
    role = EXCLUDED.role,
    region = EXCLUDED.region,
    display_name = EXCLUDED.display_name;

CREATE TABLE IF NOT EXISTS governance.policies (
    policy_key text PRIMARY KEY,
    cedar text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Concrete policies are intentional in this first test: they let us prove
-- Postgres -> Cedar compile -> Policast -> DataFusion without needing a
-- separate tag-expansion/resolver service yet.
INSERT INTO governance.policies(policy_key, cedar) VALUES
('row_filter_region', $cedar$
@id("row_filter_region")
@filter_type("row_filter")
@target_table("patients")
@roles("analyst")
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
@roles("physician")
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
