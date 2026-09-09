//! Privileged, disposable integration-test worker. Never installed in the query/UI image.
//! A JSON-lines protocol lets Python coordinate genuinely independent processes,
//! hold write sessions at deterministic barriers, and inspect real storage results.
use std::{collections::{BTreeMap, HashMap}, env, io::{self, BufRead, Write}, sync::Arc, time::Instant};
use anyhow::{bail, ensure, Context, Result};
use datafusion::{arrow::{array::{ArrayRef, BooleanArray, Int32Array, Int64Array, StringArray}, datatypes::{DataType, Field, Schema}, record_batch::RecordBatch}, catalog::CatalogProvider, physical_plan::{collect, displayable, ExecutionPlan}, prelude::{SessionConfig, SessionContext}};
use datafusion_ducklake::{DuckLakeCatalog, DuckLakeTableWriter, MetadataProvider, MetadataWriter, MulticatalogManager, MulticatalogProvider, PostgresMetadataWriter, TableWriteSession, WriteMode, initialize_multicatalog_schema};
use datafusion_ducklake::maintenance::{ExpireCriteria, CleanupCriteria, cleanup_old_files_in_catalog, delete_orphaned_files_multicatalog};
use futures::TryStreamExt;
use object_store::{ObjectStore, ObjectStoreExt, path::Path, aws::AmazonS3Builder};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use url::Url;
mod measured_store;
use measured_store::MeasuredStore;
#[cfg(not(feature = "df54"))]
#[path = "../../app/src/query_runtime.rs"]
mod query_runtime;

fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> { v[k].as_str().with_context(|| format!("missing string {k}")) }
fn name(v: &Value, k: &str) -> Result<String> {
    let s = text(v,k)?;
    ensure!(!s.is_empty() && s.len()<100 && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b==b'_'), "invalid identifier {k}");
    Ok(s.to_string())
}
fn batch(v: &Value) -> Result<RecordBatch> {
    let fields=v["fields"].as_array().context("fields array required")?;
    let rows=v["rows"].as_array().context("rows array required")?;
    ensure!(!fields.is_empty(), "empty schema");
    let mut fs=Vec::new(); let mut arrays: Vec<ArrayRef>=Vec::new();
    for f in fields {
        let n=text(f,"name")?; let nullable=f["nullable"].as_bool().unwrap_or(false);
        for r in rows { ensure!(r.is_object() && (nullable || !r[n].is_null()), "missing required {n}"); }
        macro_rules! vals { ($m:ident) => { rows.iter().map(|r| if r[n].is_null() {Ok(None)} else {r[n].$m().map(Some).context("bad field value")}).collect::<Result<Vec<_>>>()? }; }
        let (dt,a):(DataType,ArrayRef)=match text(f,"type")? {
            "string" => (DataType::Utf8, Arc::new(StringArray::from(vals!(as_str)))),
            "int64" => (DataType::Int64, Arc::new(Int64Array::from(vals!(as_i64)))),
            "int32" => {let vs=vals!(as_i64).into_iter().map(|v| v.map(i32::try_from).transpose()).collect::<std::result::Result<Vec<_>,_>>()?; (DataType::Int32, Arc::new(Int32Array::from(vs)))},
            "bool" => (DataType::Boolean, Arc::new(BooleanArray::from(vals!(as_bool)))),
            other => bail!("unsupported test field type {other}"),
        };
        fs.push(Field::new(n,dt,nullable)); arrays.push(a);
    }
    Ok(RecordBatch::try_new(Arc::new(Schema::new(fs)),arrays)?)
}
fn rows_json(batches:&[RecordBatch]) -> Result<Value> {
    let mut w=datafusion::arrow::json::ArrayWriter::new(Vec::new());
    w.write_batches(&batches.iter().collect::<Vec<_>>())?; w.finish()?;
    Ok(serde_json::from_slice(&w.into_inner())?)
}
struct Worker {
    pool: PgPool, store: Arc<MeasuredStore>, root: String,
    sessions: HashMap<String,TableWriteSession>, contexts: HashMap<String,SessionContext>,
    locks: HashMap<String,sqlx::Transaction<'static,sqlx::Postgres>>,
}
impl Worker {
    async fn writer(&self, cat:&str) -> Result<Arc<PostgresMetadataWriter>> {
        let id=MulticatalogManager::new(self.pool.clone()).find_catalog_id(cat).await?.context("catalog not initialized")?;
        Ok(Arc::new(PostgresMetadataWriter::with_pool(self.pool.clone(),id).await?))
    }
    async fn catalog(&self,cat:&str,snapshot:Option<i64>,writable:bool) -> Result<Arc<DuckLakeCatalog>> {
        let p=Arc::new(MulticatalogProvider::with_pool(self.pool.clone(),cat).await?);
        let c=if writable {DuckLakeCatalog::with_writer(p,self.writer(cat).await?)?}
        else {let s=snapshot.unwrap_or(p.get_current_snapshot()?); DuckLakeCatalog::with_snapshot(p,s)?};
        Ok(Arc::new(c))
    }
    async fn context(&self,v:&Value,writable:bool) -> Result<(SessionContext,Arc<DuckLakeCatalog>)> {
        let cat=self.catalog(text(v,"catalog")?,v["snapshot"].as_i64(),writable).await?;
        let ctx=SessionContext::new_with_config(SessionConfig::new().with_default_catalog_and_schema("lake","public"));
        ctx.register_object_store(&Url::parse("s3://lake/")?,self.store.clone());
        if v["governed"].as_bool().unwrap_or(false) {
            #[cfg(feature = "df54")]
            bail!("UNSUPPORTED: Policast is pinned to DataFusion 53; DF54 has no governed adapter");
            #[cfg(not(feature = "df54"))]
            {
                use policast_core::{parse_policies, PolicyManifest};
                use policast_datafusion::AttrIdentity;
                let table=text(v,"table")?;
                let source=cat.schema("public").context("schema missing")?.table(table).await?.context("table missing")?;
                let mut manifest=PolicyManifest::new();
                manifest.compile_policies(&parse_policies(text(v,"cedar")?).map_err(|e|anyhow::anyhow!(e.to_string()))?).map_err(|e|anyhow::anyhow!(e.to_string()))?;
                let identity=AttrIdentity::new().with("tenant","t0").with("role","reader");
                ctx.register_table(table,Arc::new(query_runtime::ReadBoundary::new(source,manifest,table,identity)))?;
            }
        } else { ctx.register_catalog("lake",cat.clone()); }
        Ok((ctx,cat))
    }
    async fn sql_rows(&self,sql:&str,cat:&str) -> Result<Vec<Value>> {
        let rs=sqlx::query(sql).bind(cat).fetch_all(&self.pool).await?;
        rs.into_iter().map(|r| Ok(serde_json::from_str(r.try_get::<String,_>(0)?.as_str())?)).collect()
    }
    async fn query(&self,ctx:&SessionContext,v:&Value) -> Result<Value> {
        self.store.reset(); let start=Instant::now();
        let df=ctx.sql(text(v,"sql")?).await?;
        let plan=df.create_physical_plan().await?;
        let schema=plan.schema(); let plan_ms=start.elapsed().as_secs_f64()*1000.;
        if v["plan_only"].as_bool().unwrap_or(false) {return Ok(json!({"planning_ms":plan_ms,"plan":displayable(plan.as_ref()).indent(true).to_string(),"io":self.store.measurements()}));}
        let exec=Instant::now(); let bs=collect(plan.clone(),ctx.task_ctx()).await?;
        let mut metrics=BTreeMap::<String,usize>::new();
        fn visit(p:&Arc<dyn ExecutionPlan>,m:&mut BTreeMap<String,usize>) {
            if let Some(ms)=p.metrics() {for metric in ms.iter() {let value=metric.value(); *m.entry(value.name().to_string()).or_default()+=value.as_usize();}}
            for c in p.children() {visit(c,m);}
        }
        visit(&plan,&mut metrics);
        Ok(json!({"rows":rows_json(&bs)?,"schema":schema.fields().iter().map(|f|json!({"name":f.name(),"type":format!("{:?}",f.data_type()),"nullable":f.is_nullable()})).collect::<Vec<_>>(),"planning_ms":plan_ms,"execution_ms":exec.elapsed().as_secs_f64()*1000.,"plan":displayable(plan.as_ref()).indent(true).to_string(),"metrics":metrics,"io":self.store.measurements()}))
    }
    async fn handle(&mut self,v:Value) -> Result<Value> {
        let op=text(&v,"op")?;
        if op=="hello" {return Ok(json!({"lane":if cfg!(feature="df54"){"df54"}else{"df53"},"arch":env::consts::ARCH,"pid":std::process::id(),"build":env!("CARGO_PKG_VERSION")}));}
        let cat=name(&v,"catalog")?;
        let mgr=MulticatalogManager::new(self.pool.clone());
        match op {
            "init" => {
                initialize_multicatalog_schema(&self.pool).await?;
                let id=mgr.create_catalog(&cat).await?;
                let w=self.writer(&cat).await?; w.set_data_path(&self.root)?;
                Ok(json!({"catalog_id":id}))
            },
            "write" | "begin" => {
                let table=name(&v,"table")?; let b=batch(&v)?;
                let tw=DuckLakeTableWriter::new(self.writer(&cat).await?,self.store.clone())?.with_max_row_group_rows(128);
                let mode=match v["mode"].as_str().unwrap_or("replace") {"replace"=>WriteMode::Replace,"append"=>WriteMode::Append,_=>bail!("bad mode")};
                let mut s=tw.begin_write("public",&table,b.schema().as_ref(),mode)?;
                s.write_batch(&b)?;
                if op=="begin" {
                    let token=name(&v,"token")?; ensure!(!self.sessions.contains_key(&token),"session already exists");
                    self.sessions.insert(token,s); return Ok(json!({"prepared":true}));
                }
                let r=s.finish().await?; Ok(json!({"snapshot":r.snapshot_id,"records":r.records_written,"files":r.files_written}))
            },
            "finish" => {let s=self.sessions.remove(text(&v,"token")?).context("session missing")?; let r=s.finish().await?; Ok(json!({"snapshot":r.snapshot_id,"records":r.records_written,"files":r.files_written}))},
            "abort" => {ensure!(self.sessions.remove(text(&v,"token")?).is_some(),"session missing"); Ok(json!({"aborted":true}))},
            "pin" => {let (ctx,_)=self.context(&v,false).await?; self.contexts.insert(name(&v,"token")?,ctx); Ok(json!({"pinned":true}))},
            "query" => {
                if let Some(token)=v["token"].as_str() {return self.query(self.contexts.get(token).context("pin missing")?,&v).await;}
                let (ctx,_)=self.context(&v,false).await?; self.query(&ctx,&v).await
            },
            "dml" => {let (ctx,c)=self.context(&v,true).await?;
                #[cfg(feature="df54")]
                let df=datafusion_ducklake::execute_ducklake_sql(&ctx,c.as_ref(),text(&v,"sql")?).await?;
                #[cfg(not(feature="df54"))]
                let df={let _=c; ctx.sql(text(&v,"sql")?).await?};
                Ok(json!({"rows":rows_json(&df.collect().await?)?}))
            },
            "promote" => {
                #[cfg(not(feature="df54"))] {bail!("UNSUPPORTED: datafusion-ducklake 0.3.0 has no promote_column_type API")}
                #[cfg(feature="df54")] {
                    let table=name(&v,"table")?;
                    let p=MulticatalogProvider::with_pool(self.pool.clone(),&cat).await?;
                    let s=p.get_schema_by_name("public",p.get_current_snapshot()?)?.context("schema missing")?;
                    let t=p.get_table_by_name(s.schema_id,&table,p.get_current_snapshot()?)?.context("table missing")?;
                    let snapshot=self.writer(&cat).await?.promote_column_type(t.table_id,text(&v,"column")?,text(&v,"type")?)?;
                    Ok(json!({"snapshot":snapshot}))
                }
            },
            "compact" => {
                #[cfg(not(feature="df54"))] {bail!("UNSUPPORTED: datafusion-ducklake 0.3.0 has no merge_adjacent_files API")}
                #[cfg(feature="df54")] {
                    let (ctx,c)=self.context(&v,true).await?;
                    let p=c.schema("public").context("schema missing")?.table(text(&v,"table")?).await?.context("table missing")?;
                    let t=p.as_any().downcast_ref::<datafusion_ducklake::DuckLakeTable>().context("not a DuckLakeTable")?;
                    let r=t.merge_adjacent_files(&ctx.state(),datafusion_ducklake::MergeOptions::default()).await?;
                    Ok(json!({"processed":r.files_processed,"created":r.files_created,"rows":r.rows_written}))
                }
            },
            "state" => {
                let p=MulticatalogProvider::with_pool(self.pool.clone(),&cat).await?;
                let snapshots=self.sql_rows("SELECT row_to_json(x)::text FROM (SELECT s.* FROM ducklake_snapshot s JOIN ducklake_catalog_snapshot_map m USING(snapshot_id) JOIN ducklake_catalog c USING(catalog_id) WHERE c.catalog_name=$1 ORDER BY snapshot_id) x",&cat).await?;
                let files=self.sql_rows("SELECT row_to_json(x)::text FROM (SELECT f.*, t.table_name FROM ducklake_data_file f JOIN ducklake_table t USING(table_id) JOIN ducklake_catalog_schema_map m ON m.schema_id=t.schema_id JOIN ducklake_catalog c USING(catalog_id) WHERE c.catalog_name=$1 ORDER BY f.data_file_id) x",&cat).await?;
                let columns=self.sql_rows("SELECT row_to_json(x)::text FROM (SELECT d.*,t.table_name FROM ducklake_column d JOIN ducklake_table t USING(table_id) JOIN ducklake_catalog_schema_map m ON m.schema_id=t.schema_id JOIN ducklake_catalog c USING(catalog_id) WHERE c.catalog_name=$1 ORDER BY d.table_id,d.column_order,d.begin_snapshot) x",&cat).await?;
                Ok(json!({"head":p.get_current_snapshot()?,"snapshots":snapshots,"files":files,"columns":columns}))
            },
            "expire" => {
                let ids=v["snapshots"].as_array().context("snapshots array")?.iter().map(|x|x.as_i64().context("snapshot integer")).collect::<Result<Vec<_>>>()?;
                let r=mgr.expire_snapshots_in_catalog(&cat,ExpireCriteria::Versions(ids)).await?;
                Ok(json!({"expired":r.iter().map(|x|x.snapshot_id).collect::<Vec<_>>()}))
            },
            "cleanup" | "orphans" => {
                let dry=v["dry_run"].as_bool().context("dry_run required")?;
                // Only unique disposable database/root accepted at startup. No normal demo path is reachable.
                let r=if op=="cleanup" {cleanup_old_files_in_catalog(&mgr,&cat,self.store.clone(),CleanupCriteria::All,dry).await?}
                else {delete_orphaned_files_multicatalog(&mgr,self.store.clone(),CleanupCriteria::All,dry).await?};
                Ok(json!({"paths":r}))
            },
            "objects" => {let key=Url::parse(&self.root)?.path().trim_start_matches('/').to_string(); let os=self.store.list(Some(&Path::from(key))).try_collect::<Vec<_>>().await?;
                Ok(json!({"objects":os.iter().map(|o|json!({"path":o.location.to_string(),"size":o.size})).collect::<Vec<_>>()}))},
            "orphan" => {let key=format!("{}/orphan_{}.parquet",Url::parse(&self.root)?.path().trim_matches('/'),name(&v,"token")?); self.store.put(&Path::from(key.clone()),"qualification orphan".into()).await?; Ok(json!({"path":key}))},
            "lock" => {let mut tx=self.pool.begin().await?; sqlx::query("SELECT catalog_id FROM ducklake_catalog WHERE catalog_name=$1 FOR UPDATE").bind(&cat).fetch_one(&mut *tx).await?; self.locks.insert(cat,tx); Ok(json!({"locked":true}))},
            "unlock" => {self.locks.remove(&cat).context("lock missing")?.rollback().await?; Ok(json!({"unlocked":true}))},
            _ => bail!("unknown operation {op}"),
        }
    }
}
#[tokio::main(flavor="multi_thread",worker_threads=4)]
async fn main() -> Result<()> {
    let db=env::var("DATABASE_URL").context("DATABASE_URL required")?;
    let dbname=Url::parse(&db)?.path().trim_start_matches('/').to_string();
    let root=env::var("QUALIFICATION_DATA_PATH").context("QUALIFICATION_DATA_PATH required")?;
    ensure!(env::var("QUALIFICATION_ONLY").as_deref()==Ok("1") && dbname.starts_with("ducklake_qualification_") && root.starts_with("s3://lake/_ducklake_qualification/") && !root.contains(".."),"SAFETY: worker requires dedicated qualification database and object prefix");
    let inner=AmazonS3Builder::new().with_bucket_name("lake").with_endpoint(env::var("AWS_ENDPOINT_URL")?).with_access_key_id(env::var("AWS_ACCESS_KEY_ID")?).with_secret_access_key(env::var("AWS_SECRET_ACCESS_KEY")?).with_region("us-east-1").with_allow_http(true).build()?;
    let mut w=Worker{pool:PgPoolOptions::new().max_connections(4).connect(&db).await?,store:Arc::new(MeasuredStore::new(Arc::new(inner))),root,sessions:HashMap::new(),contexts:HashMap::new(),locks:HashMap::new()};
    for line in io::stdin().lock().lines() {
        let line=line?; let result=match serde_json::from_str(&line) {Ok(v)=>w.handle(v).await,Err(e)=>Err(e.into())};
        let response=match result {Ok(v)=>json!({"ok":true,"result":v}),Err(e)=>json!({"ok":false,"error":format!("{e:#}")})};
        println!("{response}"); io::stdout().flush()?;
    }
    Ok(())
}
