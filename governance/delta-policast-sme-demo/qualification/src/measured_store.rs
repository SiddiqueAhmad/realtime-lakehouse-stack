//! Counts real object-store reads (including Parquet footer reads). No timing-only
//! claim of pruning: Python asserts row equality and compares distinct objects.
use std::{collections::BTreeSet, fmt, ops::Range, sync::{Arc, Mutex}};
use async_trait::async_trait;
use bytes::Bytes;
use futures::stream::BoxStream;
use object_store::{*, path::Path};
use serde_json::{json, Value};
#[derive(Debug, Default)]
struct Counts { requests:usize, range_bytes:u64, files:BTreeSet<String> }
#[derive(Debug)]
pub struct MeasuredStore { inner:Arc<dyn ObjectStore>, counts:Mutex<Counts> }
impl fmt::Display for MeasuredStore {fn fmt(&self,f:&mut fmt::Formatter<'_>)->fmt::Result {write!(f,"Measured({})",self.inner)}}
impl MeasuredStore {
    pub fn new(inner:Arc<dyn ObjectStore>)->Self {Self{inner,counts:Mutex::new(Counts::default())}}
    pub fn reset(&self) {*self.counts.lock().unwrap()=Counts::default();}
    fn record(&self,path:&Path,bytes:u64) {let mut c=self.counts.lock().unwrap();c.requests+=1;c.range_bytes+=bytes;c.files.insert(path.to_string());}
    pub fn measurements(&self)->Value {let c=self.counts.lock().unwrap();json!({"read_requests":c.requests,"response_range_bytes":c.range_bytes,"objects_read":c.files,"distinct_objects_read":c.files.len(),"includes_footer_reads":true})}
}
#[async_trait]
impl ObjectStore for MeasuredStore {
    async fn put_opts(&self,p:&Path,b:PutPayload,o:PutOptions)->Result<PutResult>{self.inner.put_opts(p,b,o).await}
    async fn put_multipart_opts(&self,p:&Path,o:PutMultipartOptions)->Result<Box<dyn MultipartUpload>>{self.inner.put_multipart_opts(p,o).await}
    async fn get_opts(&self,p:&Path,o:GetOptions)->Result<GetResult>{let head=o.head;let r=self.inner.get_opts(p,o).await?;if !head {self.record(p,r.range.end-r.range.start);}Ok(r)}
    async fn get_ranges(&self,p:&Path,r:&[Range<u64>])->Result<Vec<Bytes>> {let bs=self.inner.get_ranges(p,r).await?;self.record(p,bs.iter().map(|b|b.len() as u64).sum());Ok(bs)}
    fn delete_stream(&self,p:BoxStream<'static,Result<Path>>)->BoxStream<'static,Result<Path>>{self.inner.delete_stream(p)}
    fn list(&self,p:Option<&Path>)->BoxStream<'static,Result<ObjectMeta>>{self.inner.list(p)}
    fn list_with_offset(&self,p:Option<&Path>,o:&Path)->BoxStream<'static,Result<ObjectMeta>>{self.inner.list_with_offset(p,o)}
    async fn list_with_delimiter(&self,p:Option<&Path>)->Result<ListResult>{self.inner.list_with_delimiter(p).await}
    async fn copy_opts(&self,f:&Path,t:&Path,o:CopyOptions)->Result<()>{self.inner.copy_opts(f,t,o).await}
    async fn rename_opts(&self,f:&Path,t:&Path,o:RenameOptions)->Result<()>{self.inner.rename_opts(f,t,o).await}
}
