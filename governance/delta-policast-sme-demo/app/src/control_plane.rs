use std::collections::BTreeMap;

use anyhow::{bail, Context, Result};
use policast_core::PolicyManifest;

/// Convert the JSONB principal attribute bag into Policast's string-valued
/// identity map, then overlay reserved identity fields from authoritative
/// columns/arguments so JSONB cannot spoof them.
pub fn build_principal_attributes(
    principal_key: &str,
    role: &str,
    display_name: Option<&str>,
    attributes_json: &str,
) -> Result<BTreeMap<String, String>> {
    let value: serde_json::Value = serde_json::from_str(attributes_json)
        .with_context(|| format!("parse attributes JSON for principal {principal_key:?}"))?;
    let object = value
        .as_object()
        .with_context(|| format!("principal {principal_key:?} attributes must be a JSON object"))?;

    let mut attributes = BTreeMap::new();
    for (attr_key, attr_value) in object {
        let Some(value) = attr_value.as_str() else {
            bail!(
                "principal {principal_key:?} attribute {attr_key:?} must be a string; current Policast principal attributes are string-valued"
            );
        };
        attributes.insert(attr_key.clone(), value.to_string());
    }

    // Reserved fields are authoritative and overwrite same-named JSON keys.
    attributes.insert("role".to_string(), role.to_string());
    attributes.insert("principal_id".to_string(), principal_key.to_string());
    if let Some(name) = display_name {
        attributes.insert("name".to_string(), name.to_string());
    } else {
        // Do not allow a stale/spoofed JSON value to survive when the
        // authoritative display_name is absent.
        attributes.remove("name");
    }

    Ok(attributes)
}

/// Build the binding selectors accepted by the Postgres mini-resolver.
pub fn binding_selectors(principal_key: &str, role: &str) -> (String, String) {
    (
        format!("role:{role}"),
        format!("principal:{principal_key}"),
    )
}

/// Fail closed when a resolved policy references principal attributes that
/// are missing from the current dynamic identity.
pub fn validate_principal_contract(
    manifest: &PolicyManifest,
    principal_key: &str,
    attributes: &BTreeMap<String, String>,
) -> Result<()> {
    let Some(contract) = &manifest.principal_contract else {
        return Ok(());
    };

    let missing: Vec<&str> = contract
        .required_attributes
        .iter()
        .map(String::as_str)
        .filter(|attr| !attributes.contains_key(*attr))
        .collect();

    if !missing.is_empty() {
        bail!(
            "ACCESS_DENIED: principal {principal_key:?} is missing attributes required by resolved policies: {}",
            missing.join(", ")
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use policast_core::{parse_policies, PolicyManifest};

    fn manifest_from_cedar(cedar: &str) -> PolicyManifest {
        let parsed = parse_policies(cedar).expect("Cedar should parse");
        let mut manifest = PolicyManifest::new();
        manifest
            .compile_policies(&parsed)
            .expect("Cedar should compile");
        manifest
    }

    #[test]
    fn arbitrary_attributes_are_preserved_without_rust_fields() {
        let attrs = build_principal_attributes(
            "alice",
            "analyst",
            Some("Alice"),
            r#"{"region":"us-east","department":"finance","company_id":"c-01"}"#,
        )
        .unwrap();

        assert_eq!(attrs.get("region").map(String::as_str), Some("us-east"));
        assert_eq!(
            attrs.get("department").map(String::as_str),
            Some("finance")
        );
        assert_eq!(attrs.get("company_id").map(String::as_str), Some("c-01"));
        assert_eq!(attrs.get("role").map(String::as_str), Some("analyst"));
        assert_eq!(
            attrs.get("principal_id").map(String::as_str),
            Some("alice")
        );
        assert_eq!(attrs.get("name").map(String::as_str), Some("Alice"));
    }

    #[test]
    fn reserved_identity_fields_cannot_be_spoofed_by_json() {
        let attrs = build_principal_attributes(
            "alice",
            "analyst",
            Some("Real Alice"),
            r#"{"role":"admin","principal_id":"mallory","name":"Fake Alice","region":"us-east"}"#,
        )
        .unwrap();

        assert_eq!(attrs.get("role").map(String::as_str), Some("analyst"));
        assert_eq!(
            attrs.get("principal_id").map(String::as_str),
            Some("alice")
        );
        assert_eq!(attrs.get("name").map(String::as_str), Some("Real Alice"));
    }

    #[test]
    fn missing_authoritative_name_removes_spoofed_json_name() {
        let attrs = build_principal_attributes(
            "alice",
            "analyst",
            None,
            r#"{"name":"Spoofed","region":"us-east"}"#,
        )
        .unwrap();

        assert!(!attrs.contains_key("name"));
    }

    #[test]
    fn non_string_principal_attribute_is_rejected() {
        let err = build_principal_attributes(
            "alice",
            "analyst",
            None,
            r#"{"region":"us-east","clearance":7}"#,
        )
        .unwrap_err();

        let msg = err.to_string();
        assert!(msg.contains("clearance"));
        assert!(msg.contains("must be a string"));
    }

    #[test]
    fn binding_selectors_match_supported_control_plane_shape() {
        let (role, principal) = binding_selectors("alice", "analyst");
        assert_eq!(role, "role:analyst");
        assert_eq!(principal, "principal:alice");
    }

    #[test]
    fn dynamic_cedar_attribute_is_derived_into_contract() {
        let manifest = manifest_from_cedar(
            r#"
@id("doctor_scope")
@filter_type("row_filter")
@target_table("patients")
permit (principal, action == Action::"query", resource)
when { resource.treating_physician == principal.doctor_scope };
"#,
        );

        let required = &manifest
            .principal_contract
            .as_ref()
            .expect("principal contract")
            .required_attributes;
        assert!(required.iter().any(|a| a == "doctor_scope"));
    }

    #[test]
    fn principal_contract_accepts_complete_dynamic_identity() {
        let manifest = manifest_from_cedar(
            r#"
@id("company_department")
@filter_type("row_filter")
@target_table("patients")
permit (principal, action == Action::"query", resource)
when {
    resource.company_id == principal.company_id &&
    resource.department == principal.department
};
"#,
        );

        let attrs = BTreeMap::from([
            ("company_id".to_string(), "c-01".to_string()),
            ("department".to_string(), "finance".to_string()),
        ]);

        validate_principal_contract(&manifest, "alice", &attrs).unwrap();
    }

    #[test]
    fn principal_contract_fails_closed_when_dynamic_attribute_is_missing() {
        let manifest = manifest_from_cedar(
            r#"
@id("company_department")
@filter_type("row_filter")
@target_table("patients")
permit (principal, action == Action::"query", resource)
when {
    resource.company_id == principal.company_id &&
    resource.department == principal.department
};
"#,
        );

        let attrs = BTreeMap::from([("company_id".to_string(), "c-01".to_string())]);
        let err = validate_principal_contract(&manifest, "alice", &attrs).unwrap_err();

        let msg = err.to_string();
        assert!(msg.contains("ACCESS_DENIED"));
        assert!(msg.contains("department"));
    }

    #[test]
    fn manifest_without_principal_contract_is_allowed() {
        let manifest = manifest_from_cedar(
            r#"
@id("fixed_country")
@filter_type("row_filter")
@target_table("patients")
permit (principal, action == Action::"query", resource)
when { resource.region == "us-east" };
"#,
        );

        assert!(manifest.principal_contract.is_none());
        validate_principal_contract(&manifest, "alice", &BTreeMap::new()).unwrap();
    }
}
