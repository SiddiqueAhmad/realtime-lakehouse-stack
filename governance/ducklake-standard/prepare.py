#!/usr/bin/env python3
"""Stage an isolated DF54 build from pinned sources. Original references are never edited.

Every substitution is checked. The emitted patch is retained with CI evidence.
This is a narrow local compatibility port, NOT an upstream Policast release.
"""
import argparse
import difflib
import hashlib
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
BASE = HERE.parent / 'delta-policast-sme-demo'


def replace(text, old, new, count=1):
    if text.count(old) != count:
        raise RuntimeError(f'Patch input drift: expected {count} occurrence(s) of {old[:100]!r}, got {text.count(old)}')
    return text.replace(old, new)


def stage(root, upstream, policast, patched=True):
    if root.exists(): shutil.rmtree(root)
    root.mkdir(parents=True)
    shutil.copytree(upstream, root / 'vendor/ducklake')
    shutil.copytree(policast, root / 'vendor/policast')
    changes=[]
    def edit(path, fn):
        path=root/path; before=path.read_text(); after=fn(before)
        if before != after:
            changes.extend(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile=str(path.relative_to(root)),tofile=str(path.relative_to(root))))
            path.write_text(after)

    edit('vendor/policast/Cargo.toml', lambda s: replace(replace(s,'"crates/*",','"crates/policast-core", "crates/policast-datafusion",'),'datafusion = "53.1"','datafusion = "=54.1.0"'))
    # This port only exposes the generic TableProvider boundary. Optional Delta/UC
    # adapters retain their DF53 dependencies upstream and are not part of this lane.
    edit('vendor/policast/crates/policast-datafusion/Cargo.toml', lambda _: '''[package]
name = "policast-datafusion"
version.workspace = true
edition.workspace = true
license.workspace = true
[features]
default = []
[dependencies]
policast-core = { path = "../policast-core" }
datafusion = { workspace = true }
cel-interpreter = { workspace = true }
cel-parser = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
async-trait = { workspace = true }
tokio = { workspace = true, features = ["full"] }
[dev-dependencies]
tempfile = { workspace = true }
''')
    edit('vendor/policast/crates/policast-datafusion/src/governance_table.rs', lambda s: replace(replace(s,'    fn as_any(&self) -> &dyn Any {\n        self\n    }\n',''),'        fn as_any(&self) -> &dyn Any {\n            self\n        }\n',''))
    if patched:
        # PostgreSQL SELECT 1 yields INT4; the upstream Option<i64> decoder
        # otherwise masks a genuine retryable conflict with a database error.
        edit('vendor/ducklake/src/metadata_writer_postgres_single.rs', lambda s: replace(s,
            '"SELECT 1 FROM ducklake_data_file\n',
            '"SELECT 1::BIGINT FROM ducklake_data_file\n'))
        edit('vendor/ducklake/src/catalog.rs', lambda s: replace(s,
            'pub fn with_snapshot(provider: Arc<dyn MetadataProvider>, snapshot_id: i64) -> Result<Self> {\n',
            'pub fn with_snapshot(provider: Arc<dyn MetadataProvider>, snapshot_id: i64) -> Result<Self> {\n        // Reject unavailable history instead of returning a plausible empty result.\n        crate::metadata_provider::require_snapshot(provider.as_ref(), snapshot_id)?;\n'))
        edit('vendor/ducklake/src/metadata_writer_postgres_single.rs', lambda s: replace(s,
            '    // Classify this commit as DDL vs pure data write.',
            '''    // A prepared write must not reconcile an old schema over a newer DDL.
    // insert_snapshot holds the transactional snapshot-counter lock until commit;
    // the check and column reconciliation are in that SAME transaction.
    let schema_changed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ducklake_schema_versions WHERE table_id = $1 AND begin_snapshot > $2)",
    ).bind(table_id).bind(base_snapshot).fetch_one(&mut **tx).await?;
    if schema_changed {
        return Err(crate::DuckLakeError::Conflict(format!(
            "schema changed since snapshot {base_snapshot}; reopen the table and retry"
        )));
    }

    // Classify this commit as DDL vs pure data write.'''))
        edit('vendor/ducklake/src/metadata_writer_postgres_single.rs', lambda s: replace(s,
            '    let proposed_ids = column_ids.iter().copied().collect::<HashSet<_>>();',
            '''    let proposed_ids = column_ids.iter().copied().collect::<HashSet<_>>();
    // Append is never a DROP COLUMN command, including sequential stale schemas.
    if mode == WriteMode::Append {
        for row in &current {
            let id: i64 = row.try_get("column_id")?;
            if !proposed_ids.contains(&id) {
                return Err(crate::DuckLakeError::Conflict(
                    "append schema omits a live column; reopen the table and retry".to_string(),
                ));
            }
        }
    }'''))

    src=root/'src';src.mkdir()
    for name in ['cli.rs','catalog.rs','control_plane.rs','principal_lookup.rs','query_runtime.rs']:
        s=(BASE/'app/src'/name).read_text()
        if name=='query_runtime.rs':s=replace(s,'    fn as_any(&self) -> &dyn Any { self }\n','')
        (src/name).write_text(s)
    shutil.copy(HERE/'backend.rs',src/'backend.rs')
    shutil.copy(HERE/'query.rs',src/'query.rs')
    for name in ['measured_store.rs','plan_metrics.rs']:
        shutil.copy(BASE/'qualification/src'/name,src/name)
    s=(BASE/'app/src/bin/seed-ducklake-fixture.rs').read_text()
    start=s.index('    initialize_multicatalog_schema(&pool)')
    end=s.index('    writer.set_data_path(&data_path)?;',start)
    s=s[:start]+'''    let pool = backend::catalog_pool(&pool, &catalog_name, true).await?;
    let writer = Arc::new(datafusion_ducklake::PostgresSingleCatalogMetadataWriter::from_pool(pool));
    writer.initialize_schema()?;
'''+s[end:]
    s=replace(s,'    initialize_multicatalog_schema,','')
    s='mod backend;\n'+s
    (src/'seed.rs').write_text(s)

    s=(BASE/'qualification/src/main.rs').read_text()
    s=replace(s,'#[cfg(not(feature = "df54"))]\n#[path = "../../app/src/query_runtime.rs"]\nmod query_runtime;','mod query_runtime;\nmod backend;')
    s=replace(s,'    async fn writer(&self, cat:&str) -> Result<Arc<PostgresMetadataWriter>> {\n        let id=MulticatalogManager::new(self.pool.clone()).find_catalog_id(cat).await?.context("catalog not initialized")?;\n        Ok(Arc::new(PostgresMetadataWriter::with_pool(self.pool.clone(),id).await?))\n    }', '''    async fn writer(&self, cat:&str) -> Result<Arc<datafusion_ducklake::PostgresSingleCatalogMetadataWriter>> {
        Ok(Arc::new(datafusion_ducklake::PostgresSingleCatalogMetadataWriter::from_pool(self.catalog_pool(cat).await?)))
    }
    async fn catalog_pool(&self,cat:&str) -> Result<PgPool> {
        let mut pools=self.pools.lock().await;
        if let Some(p)=pools.get(cat) {return Ok(p.clone())}
        let p=backend::catalog_pool(&self.pool,cat,false).await?;
        pools.insert(cat.to_owned(),p.clone()); Ok(p)
    }''')
    s=replace(s,'    pool: PgPool, store:', '    pools: tokio::sync::Mutex<backend::CatalogPoolCache>,\n    pool: PgPool, store:')
    s=replace(s,'MulticatalogProvider::with_pool(self.pool.clone(),cat).await?', 'datafusion_ducklake::PostgresMetadataProvider::from_pool(self.catalog_pool(cat).await?)')
    s=replace(s,'MulticatalogProvider::with_pool(self.pool.clone(),&cat).await?', 'datafusion_ducklake::PostgresMetadataProvider::from_pool(self.catalog_pool(&cat).await?)', count=2)
    s=replace(s,'            #[cfg(feature = "df54")]\n            bail!("UNSUPPORTED: Policast is pinned to DataFusion 53; DF54 has no governed adapter");\n            #[cfg(not(feature = "df54"))]\n', '')
    s=replace(s,'sqlx::query(sql).bind(cat).fetch_all(&self.pool).await?', 'sqlx::query(sql).fetch_all(&self.catalog_pool(cat).await?).await?')
    s=replace(s,'''                initialize_multicatalog_schema(&self.pool).await?;
                let id=mgr.create_catalog(&cat).await?;
                let w=self.writer(&cat).await?; w.set_data_path(&self.root)?;
                Ok(json!({"catalog_id":id}))''', '''                let p=backend::catalog_pool(&self.pool,&cat,true).await?;
                self.pools.lock().await.insert(cat.clone(),p);
                let w=self.writer(&cat).await?; w.initialize_schema()?;
                w.set_data_path(&format!("{}/{}",self.root,cat))?;
                Ok(json!({"catalog_layout":"standard-postgres","metadata_schema":backend::schema_name(&cat)?}))''')
    a=s.index('                let snapshots=self.sql_rows(');b=s.index('                Ok(json!({"head":',a)
    s=s[:a]+'''                let snapshots=self.sql_rows("SELECT row_to_json(x)::text FROM (SELECT * FROM ducklake_snapshot ORDER BY snapshot_id) x",&cat).await?;
                let files=self.sql_rows("SELECT row_to_json(x)::text FROM (SELECT f.*,t.table_name FROM ducklake_data_file f JOIN ducklake_table t USING(table_id) ORDER BY f.data_file_id) x",&cat).await?;
                let columns=self.sql_rows("SELECT row_to_json(x)::text FROM (SELECT d.*,t.table_name FROM ducklake_column d JOIN ducklake_table t USING(table_id) ORDER BY d.table_id,d.column_order,d.begin_snapshot) x",&cat).await?;
'''+s[b:]
    a=s.index('            "expire" =>');b=s.index('            "objects" =>',a)
    s=s[:a]+'''            "expire" => {
                let ids=v["snapshots"].as_array().context("snapshots array")?.iter().map(|x|x.as_i64().context("snapshot integer")).collect::<Result<Vec<_>>>()?;
                // This controlled fixture removes listing entries ONLY. It proves
                // invalid/expired snapshot rejection, NOT native maintenance support.
                let expired=backend::expire_fixture_snapshots(&self.catalog_pool(&cat).await?,&ids).await?;
                Ok(json!({"expired":expired,"mechanism":"logical-expiry-fixture; no file/catalog GC"}))
            },
            "cleanup" | "orphans" | "native_expire" => bail!("UNSUPPORTED: upstream standard PostgreSQL catalog has no native cleanup/expiry/orphan API in 0.7.0"),
'''+s[b:]
    s=replace(s,'let mut tx=self.pool.begin().await?; sqlx::query("SELECT catalog_id FROM ducklake_catalog WHERE catalog_name=$1 FOR UPDATE").bind(&cat).fetch_one(&mut *tx).await?', 'let mut tx=self.catalog_pool(&cat).await?.begin().await?; sqlx::query("SELECT value FROM ducklake_metadata WHERE key=\'next_snapshot_id\' AND scope IS NULL FOR UPDATE").fetch_one(&mut *tx).await?')
    s=replace(s,'        let mgr=MulticatalogManager::new(self.pool.clone());\n','')
    s=replace(s,'let mut w=Worker{pool:', 'let mut w=Worker{pools:tokio::sync::Mutex::new(backend::CatalogPoolCache::default()),pool:')
    (src/'worker.rs').write_text(s)
    shutil.copy(HERE/'Cargo.toml',root/'Cargo.toml')
    lock=HERE/'Cargo.lock'
    if lock.exists():shutil.copy(lock,root/'Cargo.lock')
    (root/'upstream-changes.patch').write_text(''.join(changes))
    return root


if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--upstream',type=Path,required=True);p.add_argument('--policast',type=Path,required=True);p.add_argument('--unpatched',action='store_true')
    a=p.parse_args();stage(a.output,a.upstream,a.policast,not a.unpatched)
