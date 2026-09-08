-- Upgrade the original five-policy demo without resetting Postgres or MinIO.
-- Run from the demo directory with:
-- docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
--   -U governance -d governance < postgres/migrations/001_dynamic_governance.sql
-- This is a demo migration, not a general Cedar-to-binding migration.
BEGIN;
SELECT pg_advisory_xact_lock(74014, 1);

DO $preflight$
BEGIN
    IF to_regclass('governance.principals') IS NULL
       OR to_regclass('governance.policies') IS NULL THEN
        RAISE EXCEPTION 'Expected an initialized governance demo database; migration aborted';
    END IF;
END;
$preflight$;

CREATE TABLE IF NOT EXISTS governance.schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

DO $migration$
DECLARE
    had_attributes boolean;
    had_bindings boolean;
BEGIN
    IF EXISTS (
        SELECT 1 FROM governance.schema_migrations
        WHERE version = '001_dynamic_governance'
    ) THEN
        RAISE NOTICE '001_dynamic_governance already applied; no data changed';
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'governance' AND table_name = 'principals'
          AND column_name = 'attributes'
    ) INTO had_attributes;
    had_bindings := to_regclass('governance.policy_bindings') IS NOT NULL;

    -- Do not guess assignments for a custom legacy policy set. Its explicit
    -- bindings must be reviewed/created before using this migration.
    IF NOT had_bindings AND (
        (SELECT count(*) FROM governance.policies) <> 5
        OR EXISTS (
            SELECT 1 FROM governance.policies
            WHERE policy_key NOT IN (
                'row_filter_region', 'row_filter_physician',
                'mask_ssn', 'mask_diagnosis', 'deny_legal_hold'
            )
        )
    ) THEN
        RAISE EXCEPTION 'Custom legacy policies detected: create reviewed policy_bindings first; no changes committed';
    END IF;

    IF NOT had_attributes THEN
        ALTER TABLE governance.principals
            ADD COLUMN attributes jsonb NOT NULL DEFAULT '{}'::jsonb;
        ALTER TABLE governance.principals
            ADD CONSTRAINT principals_attributes_object
            CHECK (jsonb_typeof(attributes) = 'object');

        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'governance' AND table_name = 'principals'
              AND column_name = 'region'
        ) THEN
            -- Preserve the CURRENT region (including a prior us-west test).
            -- Dynamic SQL avoids referencing a missing legacy column on a
            -- database that already uses the new shape.
            EXECUTE 'UPDATE governance.principals
                     SET attributes = jsonb_build_object(''region'', region)
                     WHERE region IS NOT NULL';
        END IF;
    END IF;

    IF NOT had_bindings THEN
        CREATE TABLE governance.policy_bindings (
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

        -- Reproduce the original demo's five assignments, not new grants.
        -- Disabled policies remain disabled. Cedar source is not rewritten.
        INSERT INTO governance.policy_bindings (
            binding_id, policy_key, target, principal_selector, precedence, enabled
        )
        SELECT v.binding_id, v.policy_key, 'patients', v.selector, v.precedence, p.enabled
        FROM (VALUES
            ('bind_region_analyst',        'row_filter_region',    'role:analyst',   100),
            ('bind_physician_own_rows',    'row_filter_physician', 'role:physician', 100),
            ('bind_mask_ssn_global',       'mask_ssn',             '*',               10),
            ('bind_mask_diagnosis_global', 'mask_diagnosis',       '*',               10),
            ('bind_legal_hold_global',     'deny_legal_hold',      '*',              100)
        ) AS v(binding_id, policy_key, selector, precedence)
        JOIN governance.policies p ON p.policy_key = v.policy_key;
    END IF;

    -- Existing dynamic attributes/bindings and all Cedar policy text survive.
    -- The marker also prevents a rerun from resurrecting a deleted binding
    -- or restoring a deliberately removed dynamic attribute.
    INSERT INTO governance.schema_migrations(version)
    VALUES ('001_dynamic_governance');
END;
$migration$;

COMMIT;
