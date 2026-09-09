use std::{env, sync::Arc};

use anyhow::{bail, Context, Result};
use datafusion::{catalog::CatalogProvider, datasource::TableProvider, prelude::SessionContext};
use datafusion_ducklake::{DuckLakeCatalog, MetadataProvider, MulticatalogProvider};
use object_store::aws::AmazonS3Builder;
use serde_json::Value;
use sqlx::PgPool;
use url::Url;

fn config_string<'a>(config: &'a Value, name: &str) -> Result<&'a str> {
    config
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .with_context(|| format!("DUCKLAKE_CONFIG_INVALID: missing string field {name:?}"))
}

fn simple_identifier(value: &str, kind: &str) -> Result<()> {
    let mut chars = value.chars();
    let valid = matches!(chars.next(), Some('a'..='z' | '_'))
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    if !valid {
        bail!("DUCKLAKE_CONFIG_INVALID: {kind} must be a simple lowercase identifier");
    }
    Ok(())
}

/// Register the S3-compatible store used by DuckLake data files in the same
/// DataFusion session that will hold the governed provider. This is storage
/// plumbing only; table selection still comes from the governance registry.
pub fn register_object_store(ctx: &SessionContext) -> Result<()> {
    let endpoint = env::var("AWS_ENDPOINT_URL").context("AWS_ENDPOINT_URL is required for DuckLake")?;
    let access_key = env::var("AWS_ACCESS_KEY_ID").context("AWS_ACCESS_KEY_ID is required for DuckLake")?;
    let secret_key = env::var("AWS_SECRET_ACCESS_KEY").context("AWS_SECRET_ACCESS_KEY is required for DuckLake")?;
    let region = env::var("AWS_REGION").unwrap_or_else(|_| "us-east-1".to_string());
    let bucket = env::var("DUCKLAKE_BUCKET").unwrap_or_else(|_| "lake".to_string());

    let store = AmazonS3Builder::new()
        .with_bucket_name(&bucket)
        .with_endpoint(endpoint)
        .with_access_key_id(access_key)
        .with_secret_access_key(secret_key)
        .with_region(region)
        .with_allow_http(true)
        .build()
        .context("build DuckLake S3 object store")?;
    let url = Url::parse(&format!("s3://{bucket}/"))?;
    ctx.register_object_store(&url, Arc::new(store));
    Ok(())
}

pub fn table_identity(table_config: &Value) -> Result<(&str, &str)> {
    let schema = config_string(table_config, "schema")?;
    let table = config_string(table_config, "table")?;
    simple_identifier(schema, "schema")?;
    simple_identifier(table, "table")?;
    Ok((schema, table))
}

/// Resolve one table from a Postgres-backed DuckLake multicatalog at a single
/// current snapshot and expose its DataFusion TableProvider. Policast wraps
/// this provider exactly as it wraps Delta and Iceberg providers.
pub async fn open_provider(
    pool: PgPool,
    source_config: &Value,
    table_config: &Value,
) -> Result<Arc<dyn TableProvider>> {
    let catalog_name = config_string(source_config, "catalog_name")?;
    simple_identifier(catalog_name, "catalog_name")?;
    let (schema_name, table_name) = table_identity(table_config)?;

    let provider = MulticatalogProvider::with_pool(pool, catalog_name)
        .await
        .with_context(|| format!("open Postgres-backed DuckLake catalog {catalog_name:?}"))?;
    let snapshot_id = provider.get_current_snapshot().context("read DuckLake current snapshot")?;
    if snapshot_id <= 0 {
        bail!("DUCKLAKE_EMPTY: catalog {catalog_name:?} has no committed snapshot");
    }

    let catalog = DuckLakeCatalog::with_snapshot(Arc::new(provider), snapshot_id)
        .context("build DuckLake DataFusion catalog")?;
    let schema = catalog
        .schema(schema_name)
        .with_context(|| format!("DuckLake schema {schema_name:?} not found at snapshot {snapshot_id}"))?;
    let table = schema
        .table(table_name)
        .await?
        .with_context(|| format!("DuckLake table {schema_name}.{table_name} not found at snapshot {snapshot_id}"))?;
    Ok(table)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_identity_is_registry_driven() {
        let cfg = serde_json::json!({"schema":"finance","table":"invoices"});
        assert_eq!(table_identity(&cfg).unwrap(), ("finance", "invoices"));
    }

    #[test]
    fn unsafe_identifiers_fail_closed() {
        for cfg in [
            serde_json::json!({"schema":"finance.raw","table":"invoices"}),
            serde_json::json!({"schema":"finance","table":"x;drop"}),
            serde_json::json!({"schema":"Finance","table":"invoices"}),
        ] {
            assert!(table_identity(&cfg).is_err());
        }
    }
}
