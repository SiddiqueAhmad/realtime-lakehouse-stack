// Trusted Iceberg fixture importer. This is test/demo setup only; the governed
// query binary remains read-only and never creates tables or fixture records.
#[path = "../iceberg_adapter.rs"]
mod iceberg_adapter;
#[path = "../storage.rs"]
mod storage;

use std::{collections::HashMap, sync::Arc};

use anyhow::{bail, Context, Result};
use datafusion::{
    arrow::{
        array::{ArrayRef, BooleanArray, Float64Array, Int64Array, StringArray},
        datatypes::{DataType, Field, Schema},
        record_batch::RecordBatch,
    },
    datasource::MemTable,
    prelude::SessionContext,
};
use iceberg::{
    arrow::arrow_schema_to_schema_auto_assign_ids,
    spec::FormatVersion,
    Catalog, NamespaceIdent, TableCreation,
};
use iceberg_datafusion::IcebergCatalogProvider;
use serde_json::Value;

fn batch(fixture: &Value) -> Result<RecordBatch> {
    let fields = fixture["fields"].as_array().context("fixture.fields must be an array")?;
    let rows = fixture["rows"].as_array().context("fixture.rows must be an array")?;
    let mut schema_fields = Vec::new();
    let mut arrays: Vec<ArrayRef> = Vec::new();
    for field in fields {
        let name = field["name"].as_str().context("field.name must be a string")?;
        let kind = field["type"].as_str().context("field.type must be a string")?;
        let nullable = field["nullable"].as_bool().unwrap_or(false);
        for row in rows {
            if !row.is_object() { bail!("fixture rows must be objects"); }
            if row[name].is_null() && !nullable { bail!("missing non-null field {name}"); }
        }
        macro_rules! values {
            ($method:ident) => {{
                rows.iter().map(|row| {
                    if row[name].is_null() { Ok(None) }
                    else { row[name].$method().map(Some).with_context(|| format!("invalid {kind} value for {name}")) }
                }).collect::<Result<Vec<_>>>()?
            }};
        }
        let (data_type, array): (DataType, ArrayRef) = match kind {
            "string" => (DataType::Utf8, Arc::new(StringArray::from(values!(as_str)))),
            "int64" => (DataType::Int64, Arc::new(Int64Array::from(values!(as_i64)))),
            "bool" => (DataType::Boolean, Arc::new(BooleanArray::from(values!(as_bool)))),
            "float64" => (DataType::Float64, Arc::new(Float64Array::from(values!(as_f64)))),
            _ => bail!("unsupported fixture type {kind:?}"),
        };
        schema_fields.push(Field::new(name, data_type, nullable));
        arrays.push(array);
    }
    Ok(RecordBatch::try_new(Arc::new(Schema::new(schema_fields)), arrays)?)
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().context("usage: seed-iceberg-fixture FIXTURE.json NAMESPACE TABLE LOCATION")?;
    let namespace_name = args.next().context("namespace is required")?;
    let table_name = args.next().context("table is required")?;
    let location = args.next().context("Iceberg table location is required")?;
    if args.next().is_some() { bail!("too many fixture arguments"); }

    let table_config = serde_json::json!({"namespace":namespace_name,"table":table_name});
    let ident = iceberg_adapter::table_ident(&table_config)?;
    let source_config = serde_json::json!({
        "catalog_name": std::env::var("ICEBERG_CATALOG_NAME").unwrap_or_else(|_| "sme".to_string()),
        "warehouse": std::env::var("ICEBERG_WAREHOUSE").unwrap_or_else(|_| "s3://lake/iceberg".to_string())
    });
    let database_url = std::env::var("ICEBERG_CATALOG_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .context("DATABASE_URL or ICEBERG_CATALOG_DATABASE_URL is required")?;
    let catalog = iceberg_adapter::build_catalog(&database_url, &source_config).await?;

    if catalog.table_exists(&ident).await? {
        let table = catalog.load_table(&ident).await?;
        if table.metadata().format_version() != FormatVersion::V3 {
            bail!("existing Iceberg fixture is not format v3");
        }
        println!("Already exists; preserving Iceberg v3 {ident}");
        return Ok(());
    }

    let namespace = NamespaceIdent::new(namespace_name.clone());
    if !catalog.namespace_exists(&namespace).await? {
        catalog.create_namespace(&namespace, HashMap::new()).await?;
    }

    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path)?)?;
    let input = batch(&fixture)?;
    let iceberg_schema = arrow_schema_to_schema_auto_assign_ids(input.schema().as_ref())?;
    catalog.create_table(
        &namespace,
        TableCreation::builder()
            .name(table_name.clone())
            .location(location)
            .schema(iceberg_schema)
            .format_version(FormatVersion::V3)
            .build(),
    ).await.context("create Iceberg v3 fixture table")?;

    // Use Iceberg's own DataFusion write path for the one-time append. This is
    // intentionally not the governed query session and not a CDC implementation.
    let catalog_provider = IcebergCatalogProvider::try_new(catalog.clone()).await?;
    let ctx = SessionContext::new();
    ctx.register_catalog("iceberg", Arc::new(catalog_provider));
    ctx.register_table(
        "fixture_input",
        Arc::new(MemTable::try_new(input.schema(), vec![vec![input]])?),
    )?;
    let insert = format!(
        "INSERT INTO iceberg.{}.{} SELECT * FROM fixture_input",
        namespace_name, table_name
    );
    ctx.sql(&insert).await?.collect().await?;

    let table = catalog.load_table(&ident).await?;
    if table.metadata().format_version() != FormatVersion::V3 {
        bail!("fixture table changed away from Iceberg format v3");
    }
    println!("Seeded Iceberg format-version=3 {ident}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_is_fixture_driven() {
        let record = batch(&serde_json::json!({
            "fields":[{"name":"code","type":"string"},{"name":"units","type":"int64"}],
            "rows":[{"code":"A","units":4}]
        })).unwrap();
        assert_eq!(record.num_rows(), 1);
        assert_eq!(record.schema().field(1).name(), "units");
    }

    #[test]
    fn invalid_fixture_type_fails() {
        assert!(batch(&serde_json::json!({
            "fields":[{"name":"x","type":"int64"}],
            "rows":[{"x":"not integer"}]
        })).is_err());
    }
}
