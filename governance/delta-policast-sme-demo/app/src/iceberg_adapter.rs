use std::sync::Arc;

use anyhow::{bail, Context, Result};
use datafusion::datasource::TableProvider;
use iceberg::{Catalog, CatalogBuilder, NamespaceIdent, TableIdent};
use iceberg::spec::FormatVersion;
use iceberg_catalog_sql::{SqlBindStyle, SqlCatalog, SqlCatalogBuilder};
use iceberg_datafusion::IcebergStaticTableProvider;
use iceberg_storage_opendal::OpenDalStorageFactory;
use serde_json::Value;

fn config_string<'a>(config: &'a Value, name: &str) -> Result<&'a str> {
    config
        .get(name)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .with_context(|| format!("ICEBERG_CONFIG_INVALID: missing string field {name:?}"))
}

pub async fn build_catalog(database_url: &str, source_config: &Value) -> Result<Arc<SqlCatalog>> {
    let catalog_name = config_string(source_config, "catalog_name")?;
    let warehouse = config_string(source_config, "warehouse")?;
    let storage = Arc::new(OpenDalStorageFactory::S3 {
        customized_credential_load: None,
    });
    let catalog = SqlCatalogBuilder::default()
        .uri(database_url)
        .warehouse_location(warehouse)
        .sql_bind_style(SqlBindStyle::DollarNumeric)
        .with_storage_factory(storage)
        .load(catalog_name, crate::storage::iceberg_s3_options())
        .await
        .context("open PostgreSQL-backed Iceberg SQL catalog")?;
    Ok(Arc::new(catalog))
}

pub fn table_ident(table_config: &Value) -> Result<TableIdent> {
    let namespace = config_string(table_config, "namespace")?;
    let table = config_string(table_config, "table")?;
    for (kind, value) in [("namespace", namespace), ("table", table)] {
        let mut chars = value.chars();
        let valid = matches!(chars.next(), Some('a'..='z' | '_'))
            && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if !valid {
            bail!("ICEBERG_CONFIG_INVALID: {kind} must be a simple lowercase identifier");
        }
    }
    Ok(TableIdent::new(
        NamespaceIdent::new(namespace.to_string()),
        table.to_string(),
    ))
}

pub async fn open_v3_provider(
    database_url: &str,
    source_config: &Value,
    table_config: &Value,
) -> Result<Arc<dyn TableProvider>> {
    let catalog = build_catalog(database_url, source_config).await?;
    let ident = table_ident(table_config)?;
    let table = catalog
        .load_table(&ident)
        .await
        .with_context(|| format!("load Iceberg table {ident}"))?;
    if table.metadata().format_version() != FormatVersion::V3 {
        bail!(
            "ICEBERG_FORMAT_UNSUPPORTED: reference requires format v3, found {:?}",
            table.metadata().format_version()
        );
    }
    let provider = IcebergStaticTableProvider::try_new_from_table(table)
        .await
        .context("build Iceberg DataFusion TableProvider")?;
    Ok(Arc::new(provider))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_identity_is_data_driven() {
        let ident = table_ident(&serde_json::json!({"namespace":"finance","table":"invoices"})).unwrap();
        assert_eq!(ident.namespace().to_string(), "finance");
        assert_eq!(ident.name(), "invoices");
    }

    #[test]
    fn invalid_identifiers_fail_closed() {
        assert!(table_ident(&serde_json::json!({"namespace":"finance.raw","table":"invoices"})).is_err());
        assert!(table_ident(&serde_json::json!({"namespace":"finance","table":"x;drop"})).is_err());
    }
}
