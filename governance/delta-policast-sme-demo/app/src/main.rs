mod catalog;
mod cli;
mod control_plane;
mod principal_lookup;
mod query_runtime;
mod storage;

use std::sync::Arc;
use anyhow::{Context, Result};
use datafusion::{arrow::util::pretty::print_batches, datasource::TableProvider, prelude::SessionContext};
use policast_datafusion::AttrIdentity;
use sqlx::postgres::PgPoolOptions;

#[tokio::main]
async fn main() -> Result<()> {
    let args = cli::Args::parse(std::env::args().skip(1).collect())?;
    query_runtime::validate_sql(&args.sql)?;
    let pool = PgPoolOptions::new().max_connections(2)
        .connect(&std::env::var("DATABASE_URL").context("DATABASE_URL is required")?)
        .await.context("connect to governance Postgres")?;

    // One consistent control-plane snapshot for this invocation. Nothing is
    // created, seeded or migrated by the query process.
    let mut tx = pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .execute(&mut *tx).await?;
    catalog::require_schema(&mut tx).await?;
    let principal = catalog::load_principal(&mut tx, &args.principal).await?;
    let mut registrations = Vec::new();
    for key in &args.tables {
        let table = catalog::load_table(&mut tx, key).await?;
        let manifest = catalog::load_manifest(&mut tx, &args.principal, &principal.role, &table).await?;
        control_plane::validate_principal_contract(&manifest, &args.principal, &principal.attributes)?;
        registrations.push((table, manifest));
    }
    tx.commit().await?;

    deltalake::aws::register_handlers(None);
    let ctx = SessionContext::new();
    let options = storage::s3_options();
    for (registration, manifest) in registrations {
        // Delta is the only implemented adapter. Unsupported kinds are errors,
        // never silently treated as raw Parquet or an ungoverned provider.
        let table = deltalake::open_table_with_storage_options(
            deltalake::ensure_table_uri(&registration.location)?, options.clone(),
        ).await.with_context(|| format!("open registered Delta table {:?}; seed/import it separately", registration.key))?;
        table.update_datafusion_session(&ctx.state())?;
        let provider: Arc<dyn TableProvider> = Arc::new(table.table_provider().build().await?);
        let governed = query_runtime::ReadBoundary::new(
            provider, manifest, &registration.logical_name,
            AttrIdentity(principal.attributes.clone()),
        );
        ctx.register_table(registration.logical_name.as_str(), Arc::new(governed))?;
    }

    // The session contains only the explicitly requested, governed registry
    // entries. SQL cannot supply storage locations or register new sources.
    let batches = query_runtime::query(&ctx, &args.sql).await?;
    if args.json {
        let mut writer = datafusion::arrow::json::ArrayWriter::new(Vec::new());
        writer.write_batches(&batches.iter().collect::<Vec<_>>())?;
        writer.finish()?;
        println!("{}", String::from_utf8(writer.into_inner())?);
    } else {
        eprintln!("principal={} role={}", args.principal, principal.role);
        print_batches(&batches)?;
    }
    Ok(())
}
