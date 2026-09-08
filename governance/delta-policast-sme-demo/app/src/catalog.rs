use std::collections::BTreeMap;
use anyhow::{bail, Context, Result};
use policast_core::{model::{Effect, FilterType}, parse_policies, PolicyManifest};
use serde_json::Value;
use sqlx::{PgConnection, Row};
use crate::{control_plane::{binding_selectors, build_principal_attributes}, principal_lookup};

pub struct Principal {
    pub role: String,
    pub attributes: BTreeMap<String, String>,
}

pub struct RegisteredTable {
    pub key: String,
    pub logical_name: String,
    pub location: String,
    pub kind: String,
    pub source_config: Value,
    pub table_config: Value,
}

pub async fn require_schema(db: &mut PgConnection) -> Result<()> {
    let ready: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM governance.schema_migrations WHERE version='003_source_configs')"
    ).fetch_one(db).await.context("SCHEMA_MIGRATION_REQUIRED: run bash migrate.sh before querying")?;
    if !ready { bail!("SCHEMA_MIGRATION_REQUIRED: run bash migrate.sh before querying"); }
    Ok(())
}

pub async fn load_principal(db: &mut PgConnection, key: &str) -> Result<Principal> {
    let lookup = sqlx::query(
        "SELECT role, display_name, attributes::text AS attributes_json FROM governance.principals WHERE principal_key=$1"
    ).bind(key).fetch_optional(db).await;
    let row = principal_lookup::require_principal(key, lookup)?;
    let role: String = row.try_get("role")?;
    let display_name: Option<String> = row.try_get("display_name")?;
    let attributes_json: String = row.try_get("attributes_json")?;
    let attributes = build_principal_attributes(key, &role, display_name.as_deref(), &attributes_json)?;
    Ok(Principal { role, attributes })
}

pub async fn load_table(db: &mut PgConnection, key: &str) -> Result<RegisteredTable> {
    let row = sqlx::query(
        "SELECT t.table_key, t.logical_name, t.location, t.config::text AS table_config_json, \
                s.kind, s.config::text AS source_config_json \
         FROM governance.tables t JOIN governance.data_sources s ON s.source_key=t.source_key \
         WHERE t.table_key=$1 AND t.enabled AND s.enabled"
    ).bind(key).fetch_optional(db).await.context("load registered table")?
        .with_context(|| format!("ACCESS_DENIED: unknown or disabled table {key:?}"))?;
    let logical_name: String = row.try_get("logical_name")?;
    validate_logical_name(&logical_name)?;
    let source_config_json: String = row.try_get("source_config_json")?;
    let table_config_json: String = row.try_get("table_config_json")?;
    let source_config: Value = serde_json::from_str(&source_config_json).context("parse data source config JSON")?;
    let table_config: Value = serde_json::from_str(&table_config_json).context("parse table config JSON")?;
    if !source_config.is_object() || !table_config.is_object() {
        bail!("REGISTRY_INVALID: source/table config must be JSON objects");
    }
    Ok(RegisteredTable {
        key: row.try_get("table_key")?,
        logical_name,
        location: row.try_get("location")?,
        kind: row.try_get("kind")?,
        source_config,
        table_config,
    })
}

pub fn validate_logical_name(name: &str) -> Result<()> {
    let mut chars = name.chars();
    let valid = matches!(chars.next(), Some('a'..='z' | '_'))
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !valid { bail!("INVALID_TABLE_NAME: use a simple lowercase SQL identifier, not a path or qualified name"); }
    Ok(())
}

pub async fn load_manifest(
    db: &mut PgConnection, principal: &str, role: &str, table: &RegisteredTable,
) -> Result<PolicyManifest> {
    let (role_selector, principal_selector) = binding_selectors(principal, role);
    let rows = sqlx::query(
        "SELECT p.policy_key, p.cedar FROM governance.policies p WHERE p.enabled AND EXISTS ( \
         SELECT 1 FROM governance.policy_bindings b WHERE b.enabled AND b.policy_key=p.policy_key \
         AND b.target IN ('*', $1) AND b.principal_selector IN ('*', $2, $3)) ORDER BY p.policy_key"
    ).bind(&table.key).bind(role_selector).bind(principal_selector)
        .fetch_all(db).await.context("resolve policy bindings")?;
    let mut manifest = PolicyManifest::new();
    for row in rows {
        let key: String = row.try_get("policy_key")?;
        let cedar: String = row.try_get("cedar")?;
        let parsed = parse_policies(&cedar).with_context(|| format!("parse Cedar policy {key}"))?;
        manifest.compile_policies(&parsed).with_context(|| format!("compile Cedar policy {key}"))?;
    }
    scope_manifest(&mut manifest, &table.key, &table.logical_name)?;
    eprintln!("Resolved {} policies for principal={principal} table={}", manifest.policies.len(), table.key);
    Ok(manifest)
}

// Bindings reference stable table keys. Exact Cedar targets must agree; there
// is no suffix matching across catalogs. The engine receives logical aliases.
pub fn scope_manifest(manifest: &mut PolicyManifest, key: &str, alias: &str) -> Result<()> {
    let mut has_allow = false;
    for policy in &mut manifest.policies {
        if policy.is_tag_scoped() {
            bail!("POLICY_INVALID: unresolved tags in policy {}; tag resolution is not implemented", policy.id);
        }
        if policy.target_table != "*" && policy.target_table != key {
            bail!("POLICY_INVALID: binding and Cedar target disagree for {}", policy.id);
        }
        has_allow |= policy.filter_type == FilterType::RowFilter && policy.effect == Effect::Permit;
        policy.target_table = alias.to_string();
        // Assignment is solely controlled by explicit bindings in this demo.
        policy.applies_to = None;
    }
    if !has_allow {
        bail!("ACCESS_DENIED: no bound permit row policy for table {key:?}; masks/deny rules do not grant access");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn compile(source: &str) -> PolicyManifest {
        let mut m = PolicyManifest::new();
        m.compile_policies(&parse_policies(source).unwrap()).unwrap(); m
    }
    #[test]
    fn names_are_not_storage_paths() {
        for bad in ["", "s3://bucket/table", "a.b", "X", "t;drop"] { assert!(validate_logical_name(bad).is_err()); }
        validate_logical_name("ledger_2026").unwrap();
    }
    #[test]
    fn empty_manifest_denies() { assert!(scope_manifest(&mut PolicyManifest::new(), "a", "a").is_err()); }
    #[test]
    fn denies_are_not_grants() {
        let mut m = compile("@filter_type(\"deny_override\") forbid(principal,action,resource) when { resource.blocked == true };");
        assert!(scope_manifest(&mut m, "a", "a").is_err());
    }
    #[test]
    fn registered_alias_is_bound_explicitly() {
        let mut m = compile("@target_table(\"stable-key\") permit(principal,action,resource) when { resource.tenant == principal.tenant };");
        scope_manifest(&mut m, "stable-key", "ledger").unwrap();
        assert_eq!(m.policies[0].target_table, "ledger");
    }
    #[test]
    fn wrong_target_fails_instead_of_disabling_filter() {
        let mut m = compile("@target_table(\"other\") permit(principal,action,resource) when { resource.tenant == principal.tenant };");
        assert!(scope_manifest(&mut m, "a", "a").is_err());
    }
}
