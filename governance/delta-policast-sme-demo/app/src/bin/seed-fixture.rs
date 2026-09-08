// Trusted fixture-import utility, separate from the read-only query binary.
// Table names, schemas and sample records live in JSON files, not Rust.
#[path = "../storage.rs"]
mod storage;
use std::sync::Arc;
use anyhow::{bail, Context, Result};
use datafusion::arrow::{array::{ArrayRef, BooleanArray, Float64Array, Int64Array, StringArray}, datatypes::{DataType, Field, Schema}, record_batch::RecordBatch};
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
    let path = args.next().context("usage: seed-fixture FIXTURE.json [LOCATION_OVERRIDE]")?;
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(path)?)?;
    let uri = args.next().or_else(|| fixture["location"].as_str().map(str::to_string)).context("fixture location is required")?;
    if args.next().is_some() { bail!("too many fixture arguments"); }
    let input = batch(&fixture)?;
    deltalake::aws::register_handlers(None);
    let table = deltalake::DeltaTableBuilder::from_url(deltalake::ensure_table_uri(&uri)?)?
        .with_storage_options(storage::s3_options()).build()?;
    if table.verify_deltatable_existence().await? {
        println!("Already exists; preserving {uri}");
        return Ok(());
    }
    // WriteBuilder can create a table from batches when no snapshot exists.
    // Seed once, in a separate trusted process; never from the query path.
    deltalake::operations::write::WriteBuilder::new(table.log_store(), None)
        .with_input_batches(vec![input]).await.context("write fixture Delta table")?;
    println!("Seeded {uri}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schema_is_supplied_by_fixture() {
        let b = batch(&serde_json::json!({"fields":[{"name":"code","type":"string"},{"name":"units","type":"int64"}],"rows":[{"code":"A","units":4}]})).unwrap();
        assert_eq!(b.num_rows(), 1); assert_eq!(b.schema().field(1).name(), "units");
    }
    #[test]
    fn invalid_fixture_type_fails() {
        assert!(batch(&serde_json::json!({"fields":[{"name":"x","type":"int64"}],"rows":[{"x":"not integer"}]})).is_err());
    }
}
