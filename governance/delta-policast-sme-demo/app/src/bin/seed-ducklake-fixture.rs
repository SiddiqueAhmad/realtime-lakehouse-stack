// Trusted DuckLake fixture importer for Reference C. This is test/demo setup
// only; the governed query binary remains read-only.
use std::{env, sync::Arc};

use anyhow::{bail, Context, Result};
use datafusion::arrow::{
    array::{ArrayRef, BooleanArray, Float64Array, Int64Array, StringArray},
    datatypes::{DataType, Field, Schema},
    record_batch::RecordBatch,
};
use datafusion_ducklake::{
    DuckLakeTableWriter, MetadataWriter, MulticatalogManager, PostgresMetadataWriter,
    initialize_multicatalog_schema,
};
use object_store::aws::AmazonS3Builder;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;

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

fn object_store() -> Result<Arc<dyn object_store::ObjectStore>> {
    let endpoint = env::var("AWS_ENDPOINT_URL").context("AWS_ENDPOINT_URL is required")?;
    let access_key = env::var("AWS_ACCESS_KEY_ID").context("AWS_ACCESS_KEY_ID is required")?;
    let secret_key = env::var("AWS_SECRET_ACCESS_KEY").context("AWS_SECRET_ACCESS_KEY is required")?;
    let region = env::var("AWS_REGION").unwrap_or_else(|_| "us-east-1".to_string());
    let bucket = env::var("DUCKLAKE_BUCKET").unwrap_or_else(|_| "lake".to_string());
    Ok(Arc::new(
        AmazonS3Builder::new()
            .with_bucket_name(bucket)
            .with_endpoint(endpoint)
            .with_access_key_id(access_key)
            .with_secret_access_key(secret_key)
            .with_region(region)
            .with_allow_http(true)
            .build()?,
    ))
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    let fixture_path = args.next().context(
        "usage: seed-ducklake-fixture FIXTURE.json CATALOG SCHEMA TABLE DATA_PATH",
    )?;
    let catalog_name = args.next().context("catalog name is required")?;
    let schema_name = args.next().context("schema name is required")?;
    let table_name = args.next().context("table name is required")?;
    let data_path = args.next().context("DuckLake data_path is required")?;
    if args.next().is_some() { bail!("too many fixture arguments"); }

    let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let pool = PgPoolOptions::new().max_connections(5).connect(&database_url).await?;
    initialize_multicatalog_schema(&pool).await.context("initialize DuckLake Postgres metadata schema")?;

    let manager = MulticatalogManager::new(pool.clone());
    let catalog_id = manager.create_catalog(&catalog_name).await?;
    let writer = Arc::new(PostgresMetadataWriter::with_pool(pool, catalog_id).await?);
    writer.set_data_path(&data_path)?;

    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(fixture_path)?)?;
    let record = batch(&fixture)?;
    let table_writer = DuckLakeTableWriter::new(writer, object_store()?)?;
    let result = table_writer
        .write_table(&schema_name, &table_name, &[record])
        .await
        .context("write DuckLake fixture")?;

    println!(
        "Seeded DuckLake catalog={} schema={} table={} snapshot={} rows={}",
        catalog_name, schema_name, table_name, result.snapshot_id, result.records_written
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_schema_is_data_driven() {
        let b = batch(&serde_json::json!({
            "fields":[{"name":"code","type":"string"},{"name":"units","type":"int64"}],
            "rows":[{"code":"A","units":4}]
        })).unwrap();
        assert_eq!(b.num_rows(), 1);
        assert_eq!(b.schema().field(1).name(), "units");
    }

    #[test]
    fn unsupported_fixture_type_fails() {
        assert!(batch(&serde_json::json!({
            "fields":[{"name":"x","type":"decimal"}], "rows":[{"x":"1.2"}]
        })).is_err());
    }
}
