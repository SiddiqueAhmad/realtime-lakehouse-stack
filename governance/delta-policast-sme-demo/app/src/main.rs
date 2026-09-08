use std::{
    collections::{BTreeMap, HashMap},
    sync::Arc,
};

use anyhow::{bail, Context, Result};
use datafusion::{
    arrow::{
        array::{BooleanArray, StringArray},
        datatypes::{DataType, Field, Schema},
        record_batch::RecordBatch,
    },
    datasource::TableProvider,
    prelude::SessionContext,
};
use deltalake::{
    ensure_table_uri,
    kernel::engine::arrow_conversion::TryIntoKernel,
    operations::{create::CreateBuilder, write::WriteBuilder},
    DeltaTableBuilder,
};
use policast_core::{parse_policies, PolicyManifest};
use policast_datafusion::{AttrIdentity, GovernedTable};
use sqlx::{postgres::PgPoolOptions, Row};

const TABLE_NAME: &str = "patients";

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

    // Unknown principals fail here, before policy resolution or Delta access.
    let principal = load_principal(&pool, &principal_key).await?;

    // Resolve policy assignment from explicit Postgres bindings. Cedar source
    // no longer contains role assignment metadata.
    let manifest = load_resolved_manifest(
        &pool,
        &principal_key,
        &principal.role,
        TABLE_NAME,
    )
    .await?;

    // Dynamic identities are only safe if every principal attribute required
    // by the resolved policies is present. Policast's row-filter path can skip
    // an expression when an identity field is missing, so enforce the manifest
    // contract here and fail closed before any table is registered.
    validate_principal_contract(&manifest, &principal_key, &principal.attributes)?;

    ensure_demo_delta(&table_uri, &storage_options).await?;

    let table_url = ensure_table_uri(&table_uri).context("normalize Delta table URI")?;
    let table = deltalake::open_table_with_storage_options(table_url, storage_options.clone())
        .await
        .context("open Delta table from MinIO")?;

    let ctx = SessionContext::new();

    table
        .update_datafusion_session(&ctx.state())
        .context("register Delta object store in DataFusion")?;

    // Build the generic Delta TableProvider and wrap it directly with
    // GovernedTable so we can use AttrIdentity instead of the fixed
    // role/region/name QueryIdentity convenience type.
    let provider: Arc<dyn TableProvider> = Arc::new(
        table
            .table_provider()
            .build()
            .await
            .context("build Delta DataFusion TableProvider")?,
    );

    let identity = AttrIdentity(principal.attributes.clone());
    let governed = GovernedTable::new(provider, manifest, TABLE_NAME, identity);

    ctx.register_table(TABLE_NAME, Arc::new(governed))?;

    println!("\n=== Principal ===");
    println!("key:        {}", principal_key);
    println!("role:       {}", principal.role);
    println!("attributes: {:?}", principal.attributes);

    println!("\n=== Governed result ===");
    ctx.sql(
        "SELECT patient_id, name, ssn, diagnosis, region, treating_physician, legal_hold \
         FROM patients ORDER BY patient_id",
    )
    .await?
    .show()
    .await?;

    Ok(())
}

#[derive(Debug)]
struct Principal {
    role: String,
    attributes: BTreeMap<String, String>,
}

async fn load_principal(pool: &sqlx::PgPool, key: &str) -> Result<Principal> {
    let row = sqlx::query(
        "SELECT role, display_name, attributes::text AS attributes_json \
         FROM governance.principals WHERE principal_key = $1",
    )
    .bind(key)
    .fetch_one(pool)
    .await
    .with_context(|| format!("ACCESS_DENIED: unknown principal {key:?}"))?;

    let role: String = row.try_get("role")?;
    let display_name: Option<String> = row.try_get("display_name")?;
    let attributes_json: String = row.try_get("attributes_json")?;

    let value: serde_json::Value = serde_json::from_str(&attributes_json)
        .with_context(|| format!("parse attributes JSON for principal {key:?}"))?;
    let object = value
        .as_object()
        .with_context(|| format!("principal {key:?} attributes must be a JSON object"))?;

    let mut attributes = BTreeMap::new();
    for (attr_key, attr_value) in object {
        let Some(value) = attr_value.as_str() else {
            bail!(
                "principal {key:?} attribute {attr_key:?} must be a string; current Policast principal attributes are string-valued"
            );
        };
        attributes.insert(attr_key.clone(), value.to_string());
    }

    // Reserved identity fields are authoritative and overwrite any same-named
    // key in JSONB so business-managed attributes cannot spoof identity.
    attributes.insert("role".to_string(), role.clone());
    attributes.insert("principal_id".to_string(), key.to_string());
    if let Some(name) = display_name {
        attributes.insert("name".to_string(), name);
    }

    Ok(Principal { role, attributes })
}

/// Resolve policy assignment from Postgres.
///
/// Binding selectors supported by this POC mirror Policast's resolver shape:
///   * `*`
///   * `role:<role>`
///   * `principal:<principal_key>`
///
/// Only the resolved policy set is compiled and handed to DataFusion.
async fn load_resolved_manifest(
    pool: &sqlx::PgPool,
    principal_key: &str,
    role: &str,
    table_name: &str,
) -> Result<PolicyManifest> {
    let total_enabled: i64 = sqlx::query_scalar(
        "SELECT count(*)::bigint FROM governance.policies WHERE enabled",
    )
    .fetch_one(pool)
    .await
    .context("count enabled governance policies")?;

    let role_selector = format!("role:{role}");
    let principal_selector = format!("principal:{principal_key}");

    let rows = sqlx::query(
        "SELECT p.policy_key, p.cedar \
         FROM governance.policies p \
         WHERE p.enabled \
           AND EXISTS ( \
               SELECT 1 \
               FROM governance.policy_bindings b \
               WHERE b.enabled \
                 AND b.policy_key = p.policy_key \
                 AND (b.target = '*' OR b.target = $1) \
                 AND b.principal_selector IN ('*', $2, $3) \
           ) \
         ORDER BY p.policy_key",
    )
    .bind(table_name)
    .bind(&role_selector)
    .bind(&principal_selector)
    .fetch_all(pool)
    .await
    .context("resolve policy bindings from Postgres")?;

    if rows.is_empty() {
        bail!(
            "ACCESS_DENIED: no governance policies resolved for principal={principal_key} role={role} table={table_name}"
        );
    }

    let resolved_count = rows.len();
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

    println!(
        "Loaded {total_enabled} enabled policies from Postgres; resolved and compiled {resolved_count} for principal={principal_key} role={role} table={table_name}"
    );

    Ok(manifest)
}

fn validate_principal_contract(
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

async fn ensure_demo_delta(uri: &str, storage: &HashMap<String, String>) -> Result<()> {
    let table_url = ensure_table_uri(uri).context("normalize Delta table URI")?;
    let builder = DeltaTableBuilder::from_url(table_url)?.with_storage_options(storage.clone());

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
            Arc::new(StringArray::from(vec![
                "1001", "1002", "1003", "1004", "1005", "1006",
            ])),
            Arc::new(StringArray::from(vec![
                "Alice Johnson",
                "Bob Martinez",
                "Carol White",
                "David Kim",
                "Eva Chen",
                "Frank Brown",
            ])),
            Arc::new(StringArray::from(vec![
                "123-45-6789",
                "234-56-7890",
                "345-67-8901",
                "456-78-9012",
                "567-89-0123",
                "678-90-1234",
            ])),
            Arc::new(StringArray::from(vec![
                "Hypertension",
                "Diabetes Type 2",
                "Asthma",
                "Migraine",
                "Anemia",
                "Arthritis",
            ])),
            Arc::new(StringArray::from(vec![
                "us-east", "us-west", "us-east", "eu-west", "us-west", "us-east",
            ])),
            Arc::new(StringArray::from(vec![
                "Dr. Smith",
                "Dr. Lee",
                "Dr. Smith",
                "Dr. Mueller",
                "Dr. Lee",
                "Dr. Patel",
            ])),
            Arc::new(BooleanArray::from(vec![
                false, false, false, false, true, false,
            ])),
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
