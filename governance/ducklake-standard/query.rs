//! DF54-only governed entry point. Shares baseline control-plane and ReadBoundary
//! implementations; adapter registration is the only format-specific part.
mod backend;
mod catalog;
mod cli;
mod control_plane;
mod principal_lookup;
mod query_runtime;
use std::{env, sync::Arc};
use anyhow::{bail, Context, Result};
use datafusion::{catalog::CatalogProvider, prelude::SessionContext};
use datafusion_ducklake::{DuckLakeCatalog, MetadataProvider, PostgresMetadataProvider};
use object_store::aws::AmazonS3Builder;
use policast_datafusion::AttrIdentity;
use sqlx::postgres::PgPoolOptions;
use url::Url;
#[tokio::main]
async fn main() -> Result<()> {
    let args=cli::Args::parse(env::args().skip(1).collect())?;
    query_runtime::validate_sql(&args.sql)?;
    let database_url=env::var("DATABASE_URL").context("DATABASE_URL required")?;
    let pool=PgPoolOptions::new().max_connections(4).connect(&database_url).await?;
    let mut tx=pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").execute(&mut *tx).await?;
    catalog::require_schema(&mut tx).await?;
    let principal=catalog::load_principal(&mut tx,&args.principal).await?;
    let mut registrations=Vec::new();
    for key in &args.tables {
        let table=catalog::load_table(&mut tx,key).await?;
        let manifest=catalog::load_manifest(&mut tx,&args.principal,&principal.role,&table).await?;
        control_plane::validate_principal_contract(&manifest,&args.principal,&principal.attributes)?;
        registrations.push((table,manifest));
    }
    tx.commit().await?;
    let ctx=SessionContext::new();
    let store=AmazonS3Builder::new().with_bucket_name("lake")
        .with_endpoint(env::var("AWS_ENDPOINT_URL")?)
        .with_access_key_id(env::var("AWS_ACCESS_KEY_ID")?)
        .with_secret_access_key(env::var("AWS_SECRET_ACCESS_KEY")?)
        .with_region("us-east-1").with_allow_http(true).build()?;
    ctx.register_object_store(&Url::parse("s3://lake/")?,Arc::new(store));
    let metadata_url=env::var("DUCKLAKE_DATABASE_URL").unwrap_or(database_url);
    let base=sqlx::postgres::PgPoolOptions::new().max_connections(2).connect(&metadata_url).await?;
    // Snapshot shared by all requested tables from each catalog, not reopened per table.
    let mut opened=std::collections::HashMap::<String,Arc<DuckLakeCatalog>>::new();
    for (registration,manifest) in registrations {
        if registration.kind!="ducklake_postgres" {bail!("UNSUPPORTED_SOURCE: this isolated reference supports standard DuckLake PostgreSQL only")}
        let label=registration.source_config["catalog_name"].as_str().context("catalog_name required")?;
        if !opened.contains_key(label) {
            let p=PostgresMetadataProvider::from_pool(backend::catalog_pool(&base,label,false).await?);
            let snapshot=p.get_current_snapshot()?;
            let cat=DuckLakeCatalog::with_snapshot(Arc::new(p),snapshot)?;
            opened.insert(label.to_owned(),Arc::new(cat));
        }
        let cat=&opened[label];
        let schema=registration.table_config["schema"].as_str().context("schema required")?;
        let table=registration.table_config["table"].as_str().context("table required")?;
        let provider=cat.schema(schema).context("DuckLake schema missing")?.table(table).await?.context("DuckLake table missing")?;
        ctx.register_table(registration.logical_name.as_str(),Arc::new(query_runtime::ReadBoundary::new(provider,manifest,&registration.logical_name,AttrIdentity(principal.attributes.clone()))))?;
    }
    let batches=query_runtime::query(&ctx,&args.sql).await?;
    if args.json {
        let mut writer=datafusion::arrow::json::ArrayWriter::new(Vec::new());
        writer.write_batches(&batches.iter().collect::<Vec<_>>())?;writer.finish()?;
        println!("{}",String::from_utf8(writer.into_inner())?);
    } else { datafusion::arrow::util::pretty::print_batches(&batches)?; }
    Ok(())
}
