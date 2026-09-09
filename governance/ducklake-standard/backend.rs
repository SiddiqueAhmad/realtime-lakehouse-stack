//! Standard single-catalog PostgreSQL layout. Schemas isolate catalogs in test
//! scratch databases; no MulticatalogProvider or catalog_id/map tables are used.
use anyhow::{ensure, Result};
use std::collections::{HashMap, VecDeque};
use sqlx::{postgres::PgPoolOptions, PgPool};

/// Bound idle catalog pools in long-lived test workers. Eviction drops ONLY the
/// cache's handle: a pinned reader or prepared writer retains its own pool clone.
/// Calling Pool::close here would incorrectly invalidate those active users.
#[derive(Default)]
pub struct CatalogPoolCache {
    entries: HashMap<String, PgPool>,
    order: VecDeque<String>,
}
const MAX_CACHED_CATALOG_POOLS: usize = 8;
impl CatalogPoolCache {
    pub fn get(&mut self, key: &str) -> Option<&PgPool> {
        if !self.entries.contains_key(key) { return None; }
        self.order.retain(|entry| entry != key);
        self.order.push_back(key.to_owned());
        self.entries.get(key)
    }
    pub fn insert(&mut self, key: String, pool: PgPool) {
        self.order.retain(|entry| entry != &key);
        self.order.push_back(key.clone());
        self.entries.insert(key, pool);
        while self.entries.len() > MAX_CACHED_CATALOG_POOLS {
            if let Some(oldest) = self.order.pop_front() {
                self.entries.remove(&oldest);
            }
        }
    }
}

pub fn schema_name(catalog: &str) -> Result<String> {
    ensure!(!catalog.is_empty() && catalog.len() <= 55 && catalog.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'), "invalid catalog identifier");
    Ok(format!("lake_{catalog}"))
}

pub async fn catalog_pool(base: &PgPool, catalog: &str, initialize: bool) -> Result<PgPool> {
    let schema = schema_name(catalog)?;
    if initialize {
        // Identifier cannot be a bind parameter. schema_name above restricts the
        // entire identifier to lowercase ASCII/digits/underscore and a fixed
        // prefix; quotes, whitespace, punctuation and SQL syntax are rejected.
        sqlx::query(sqlx::AssertSqlSafe(format!("CREATE SCHEMA IF NOT EXISTS \"{schema}\"")))
            .execute(base).await?;
    }
    let connect=base.connect_options().as_ref().clone();
    Ok(PgPoolOptions::new().max_connections(2).after_connect(move |conn,_| {
        let schema=schema.clone();
        Box::pin(async move {
            sqlx::query("SELECT set_config('search_path', $1, false)").bind(schema).execute(&mut *conn).await?;
            sqlx::query("SET lock_timeout = '3s'").execute(&mut *conn).await?;
            Ok(())
        })
    }).connect_with(connect).await?)
}

/// Privileged TEST FIXTURE only. Logically revoke old snapshots under the same
/// counter lock as writes. Do not reclaim data, columns or files; native standard
/// PostgreSQL maintenance is not provided by upstream 0.7.0.
pub async fn expire_fixture_snapshots(pool: &PgPool, ids: &[i64]) -> Result<Vec<i64>> {
    let mut tx=pool.begin().await?;
    sqlx::query("SELECT value FROM ducklake_metadata WHERE key='next_snapshot_id' AND scope IS NULL FOR UPDATE").fetch_one(&mut *tx).await?;
    let head: i64=sqlx::query_scalar("SELECT COALESCE(MAX(snapshot_id),0) FROM ducklake_snapshot").fetch_one(&mut *tx).await?;
    let mut expired=Vec::new();
    for id in ids {
        if *id==head {continue}
        let result=sqlx::query("DELETE FROM ducklake_snapshot WHERE snapshot_id=$1").bind(id).execute(&mut *tx).await?;
        if result.rows_affected()==1 {
            sqlx::query("DELETE FROM ducklake_snapshot_changes WHERE snapshot_id=$1").bind(id).execute(&mut *tx).await?;
            expired.push(*id);
        }
    }
    tx.commit().await?;
    Ok(expired)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn schema_identifiers_reject_sql_syntax_and_truncation() {
        for bad in ["", "public.other", "UPPER", "a\";DROP SCHEMA public;--", "a b", "x-y", "a\\b", "é"] {
            assert!(schema_name(bad).is_err(), "accepted {bad:?}");
        }
        assert!(schema_name(&"a".repeat(56)).is_err());
        assert_eq!(schema_name("tt_05").unwrap(), "lake_tt_05");
    }
    fn lazy_pool() -> PgPool {
        PgPoolOptions::new().max_connections(2)
            .connect_lazy("postgresql://unused:unused@localhost/unused").unwrap()
    }
    #[tokio::test]
    async fn cache_is_bounded_and_retains_recently_used_pools() {
        let mut cache = CatalogPoolCache::default();
        for index in 0..8 { cache.insert(format!("c{index}"), lazy_pool()); }
        assert!(cache.get("c0").is_some());
        cache.insert("c8".into(), lazy_pool());
        assert!(cache.get("c1").is_none());
        assert!(cache.get("c0").is_some());
        for index in 9..100 {
            cache.insert(format!("c{index}"), lazy_pool());
            assert_eq!(cache.entries.len(), MAX_CACHED_CATALOG_POOLS);
            assert_eq!(cache.order.len(), MAX_CACHED_CATALOG_POOLS);
        }
    }
    #[tokio::test]
    async fn eviction_does_not_close_a_pool_retained_by_a_reader() {
        let mut cache = CatalogPoolCache::default();
        let active = lazy_pool();
        cache.insert("active".into(), active.clone());
        for index in 0..8 { cache.insert(format!("c{index}"), lazy_pool()); }
        assert!(cache.get("active").is_none());
        assert!(!active.is_closed());
    }
}
