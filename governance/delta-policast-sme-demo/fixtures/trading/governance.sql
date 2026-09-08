BEGIN;
INSERT INTO governance.data_sources(source_key,kind) VALUES ('demo-delta','delta') ON CONFLICT DO NOTHING;
INSERT INTO governance.tables(table_key,source_key,logical_name,location)
VALUES ('invoices','demo-delta','invoices','s3://lake/invoices') ON CONFLICT DO NOTHING;
INSERT INTO governance.principals(principal_key,role,display_name,attributes)
VALUES ('finance_reader','finance','Finance Reader','{"company_id":"c-01","branch":"lahore"}') ON CONFLICT DO NOTHING;
INSERT INTO governance.policies(policy_key,cedar) VALUES
('invoice_company_branch',$cedar$
@id("invoice_company_branch") @filter_type("row_filter") @target_table("invoices")
permit(principal,action == Action::"query",resource)
when { resource.company_id == principal.company_id && resource.branch == principal.branch };
$cedar$),
('invoice_bank_mask',$cedar$
@id("invoice_bank_mask") @filter_type("column_mask") @target_table("invoices") @column("bank_account")
forbid(principal,action == Action::"query",resource) when { true };
$cedar$)
ON CONFLICT DO NOTHING;
INSERT INTO governance.policy_bindings(binding_id,policy_key,target,principal_selector) VALUES
('bind_invoice_finance','invoice_company_branch','invoices','role:finance'),
('bind_invoice_bank','invoice_bank_mask','invoices','*')
ON CONFLICT DO NOTHING;
COMMIT;
