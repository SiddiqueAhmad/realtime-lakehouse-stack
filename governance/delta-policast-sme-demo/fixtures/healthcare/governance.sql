-- Example metadata only. DO NOTHING preserves changes in an existing demo.
BEGIN;
INSERT INTO governance.data_sources(source_key,kind) VALUES ('demo-delta','delta') ON CONFLICT DO NOTHING;
INSERT INTO governance.tables(table_key,source_key,logical_name,location)
VALUES ('patients','demo-delta','patients','s3://lake/patients') ON CONFLICT DO NOTHING;
INSERT INTO governance.principals(principal_key,role,display_name,attributes) VALUES
('admin','admin','Platform Admin','{}'),
('analyst','analyst','Healthcare Analyst','{"region":"us-east","department":"analytics","company_id":"demo-co"}'),
('physician','physician','Dr. Smith','{"department":"clinical","company_id":"demo-co"}')
ON CONFLICT DO NOTHING;
INSERT INTO governance.policies(policy_key,cedar) VALUES
('row_filter_region',$cedar$
@id("row_filter_region") @filter_type("row_filter") @target_table("patients")
permit(principal,action == Action::"query",resource)
when { resource.region == principal.region };
$cedar$),
('row_filter_physician',$cedar$
@id("row_filter_physician") @filter_type("row_filter") @target_table("patients")
permit(principal,action == Action::"query",resource)
when { resource.treating_physician == principal.name };
$cedar$),
('mask_ssn',$cedar$
@id("mask_ssn") @filter_type("column_mask") @target_table("patients") @column("ssn")
forbid(principal,action == Action::"query",resource)
unless { principal.role == "admin" || principal.role == "physician" };
$cedar$),
('mask_diagnosis',$cedar$
@id("mask_diagnosis") @filter_type("column_mask") @target_table("patients") @column("diagnosis")
forbid(principal,action == Action::"query",resource)
unless { principal.role == "admin" || principal.role == "physician" };
$cedar$),
('deny_legal_hold',$cedar$
@id("deny_legal_hold") @filter_type("deny_override") @target_table("patients")
forbid(principal,action,resource) when { resource.legal_hold == true }
unless { principal.role == "legal" };
$cedar$),
('allow_admin_patients',$cedar$
@id("allow_admin_patients") @filter_type("row_filter") @target_table("patients")
permit(principal,action == Action::"query",resource) when { true };
$cedar$)
ON CONFLICT DO NOTHING;
INSERT INTO governance.policy_bindings(binding_id,policy_key,target,principal_selector,precedence) VALUES
('bind_region_analyst','row_filter_region','patients','role:analyst',100),
('bind_physician_own_rows','row_filter_physician','patients','role:physician',100),
('bind_mask_ssn_global','mask_ssn','patients','*',10),
('bind_mask_diagnosis_global','mask_diagnosis','patients','*',10),
('bind_legal_hold_global','deny_legal_hold','patients','*',100),
('bind_admin_patients','allow_admin_patients','patients','role:admin',100)
ON CONFLICT DO NOTHING;
COMMIT;
