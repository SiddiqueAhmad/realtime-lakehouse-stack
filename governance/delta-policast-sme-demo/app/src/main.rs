use std::{collections::HashMap, sync::Arc};

use anyhow::{Context, Result};
use datafusion::{
    arrow::{
        array::{BooleanArray, StringArray},
        datatypes::{DataType, Field, Schema},
        record_batch::RecordBatch,
    },
    prelude::SessionContext,
};
use deltalake::{
    ensure_table_uri,
    kernel::engine::arrow_conversion::TryIntoKernel,
    operations::{create::CreateBuilder, write::WriteBuilder},
    DeltaTableBuilder,
};
use policast_core::{parse_policies, PolicyManifest};
use policast_datafusion::{cel_filter::QueryIdentity, delta::wrap_delta_table};
use sqlx::{postgres::PgPoolOptions, Row};

#[tokio::main]
async fn main() -> Result<()> {
    deltalake::aws::register_handlers(None);

    let principal_key = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "analyst".to_string());

    let database_url = env("DATABASE_URL")?;
    let table_uri = env("DELTA_TABLE_URI")?;
    let storage_options = s3_options()?;

    let pool = PgPoolOptions::new()
        .max_connections(4)
        .connect(&database_url)
        .await
        .context("connect to governance Postgres")?;

    let principal = load_principal(&pool, &principal_key).await?;
    let manifest = load_manifest(&pool).await?;

    ensure_demo_delta(&table_uri, &storage_options).await?;

    // deltalake 0.32.4 accepts a parsed Url for remote table operations.
    let table_url = ensure_table_uri(&table_uri).context("normalize Delta table URI")?;
    let table = deltalake::open_table_with_storage_options(
        table_url,
        storage_options.clone(),
    )
    .await
    .context("open Delta table from MinIO")?;

    let ctx = SessionContext::new();

    // delta-rs 0.32 requires the table's object store to be registered with
    // the DataFusion session before the physical scan executes.
    table
        .update_datafusion_session(&ctx.state())
        .context("register Delta object store in DataFusion")?;

    let identity = QueryIdentity {
        role: principal.role.clone(),
        region: principal.region.clone(),
        name: principal.display_name.clone(),
    };

    // Policast currently returns Box<dyn Error> without Send + Sync here,
    // so anyhow::Context cannot be attached directly. Convert it explicitly.
    let governed = wrap_delta_table(table, manifest, "patients", identity)
        .await
        .map_err(|e| anyhow::anyhow!("wrap Delta TableProvider with Policast governance: {e}"))?;

    ctx.register_table("patients", Arc::new(governed))?;

    println!("\n=== Principal ===");
    println!("key:    {}", principal_key);
    println!("role:   {}", principal.role);
    println!("region: {:?}", principal.region);
    println!("name:   {:?}", principal.display_name);

    println!("\n=== Governed result ===");
    ctx.sql(
        "SELECT patient_id, name, ssn, diagnosis, region, treating_physician, legal_hold \
         FROM patients ORDER BY patient_id",
    )
    .await?
    .show()
    .await?;

    println!("\nExpected:");
    println!("  admin     -> all non-legal-hold rows, SSN/diagnosis visible");
    println!("  physician -> only Dr. Smith rows, SSN/diagnosis visible");
    println!("  analyst   -> only us-east rows, SSN/diagnosis masked");

    Ok(())
}

#[derive(Debug)]
struct Principal {
    role: String,
    region: Option<String>,
    display_name: Option<String>,
}

async fn load_principal(pool: &sqlx::PgPool, key: &str) -> Result<Principal> {
    let row = sqlx::query(
        "SELECT role, region, display_name \
         FROM governance.principals WHERE principal_key = $1",
    )
    .bind(key)
    .fetch_one(pool)
    .await
    .with_context(|| format!("load principal {key:?} from Postgres"))?;

    Ok(Principal {
        role: row.try_get("role")?,
        region: row.try_get("region")?,
        display_name: row.try_get("display_name")?,
    })
}

async fn load_manifest(pool: &sqlx::PgPool) -> Result<PolicyManifest> {
    let rows = sqlx::query(
        "SELECT policy_key, cedar \
         FROM governance.policies WHERE enabled ORDER BY policy_key",
    )
    .fetch_all(pool)
    .await
    .context("load Cedar policies from Postgres")?;

    let mut manifest = PolicyManifest::new();

    for row in rows {
        let key: String = row.try_get("policy_key")?;
        let cedar: String = row.try_get("cedar")?;
        let parsed = parse_policies(&cedar)
            .with_context(|| format!("parse Cedar policy {key}"))?;
        manifest
            .compile_policies(&parsed)
            .with_context(|| format!("compile Cedar policy {key} to Policast manifest"))?;
    }

    println!("Loaded and compiled {} policies from Postgres", manifest.policies.len());
    Ok(manifest)
}

async fn ensure_demo_delta(uri: &str, storage: &HashMap<String, String>) -> Result<()> {
    // deltalake 0.32.4 removed DeltaTableBuilder::from_uri. Normalize the
    // user-facing string first, then construct the builder from the Url.
    let table_url = ensure_table_uri(uri).context("normalize Delta table URI")?;
    let builder = DeltaTableBuilder::from_url(table_url)?
        .with_storage_options(storage.clone());

    let exists = builder
        .build()?
        .verify_deltatable_existence()
        .await
        .context("check Delta table existence")?;

    if exists {
        return Ok(());
    }

    println!("Delta table does not exist; seeding {uri}");

    let schema = Arc::new(Schema::new(vec![
        Field::new("patient_id", DataType::Utf8, false),
        Field::new("name", DataType::Utf8, false),
        Field::new("ssn", DataType::Utf8, false),
        Field::new("diagnosis", DataType::Utf8, false),
        Field::new("region", DataType::Utf8, false),
        Field::new("treating_physician", DataType::Utf8, false),
        Field::new("legal_hold", DataType::Boolean, false),
    ]));

    let batch = RecordBatch::try_new(
        schema.clone(),
        vec![
            Arc::new(StringArray::from(vec!["1001", "1002", "1003", "1004", "1005", "1006"])),
            Arc::new(StringArray::from(vec![
                "Alice Johnson", "Bob Martinez", "Carol White",
                "David Kim", "Eva Chen", "Frank Brown",
            ])),
            Arc::new(StringArray::from(vec![
                "123-45-6789", "234-56-7890", "345-67-8901",
                "456-78-9012", "567-89-0123", "678-90-1234",
            ])),
            Arc::new(StringArray::from(vec![
                "Hypertension", "Diabetes Type 2", "Asthma",
                "Migraine", "Anemia", "Arthritis",
            ])),
            Arc::new(StringArray::from(vec![
                "us-east", "us-west", "us-east", "eu-west", "us-west", "us-east",
            ])),
            Arc::new(StringArray::from(vec![
                "Dr. Smith", "Dr. Lee", "Dr. Smith",
                "Dr. Mueller", "Dr. Lee", "Dr. Patel",
            ])),
            Arc::new(BooleanArray::from(vec![false, false, false, false, true, false])),
        ],
    )?;

    let delta_schema: deltalake::kernel::Schema = schema.as_ref().try_into_kernel()?;

    let table = CreateBuilder::new()
        .with_location(uri)
        .with_storage_options(storage.clone())
        .with_columns(delta_schema.fields().cloned())
        .await
        .context("create Delta table")?;

    WriteBuilder::new(
        table.log_store(),
        Some(table.snapshot()?.snapshot().clone()),
    )
    .with_input_batches(vec![batch])
    .await
    .context("write seed rows to Delta table")?;

    Ok(())
}

fn s3_options() -> Result<HashMap<String, String>> {
    let mut m = HashMap::new();
    for key in [
        "AWS_ENDPOINT_URL",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_REGION",
        "AWS_ALLOW_HTTP",
        "AWS_VIRTUAL_HOSTED_STYLE_REQUEST",
        "AWS_S3_ALLOW_UNSAFE_RENAME",
    ] {
        if let Ok(value) = std::env::var(key) {
            m.insert(key.to_string(), value);
        }
    }
    Ok(m)
}

fn env(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("missing environment variable {name}"))
}
