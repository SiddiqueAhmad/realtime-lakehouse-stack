use std::{any::Any, sync::Arc};
use anyhow::{bail, Result};
use async_trait::async_trait;
use datafusion::{
    arrow::{datatypes::{DataType, SchemaRef}, record_batch::RecordBatch},
    catalog::Session,
    common::{DataFusionError, DFSchema, Result as DFResult},
    datasource::TableProvider,
    logical_expr::{Expr, TableProviderFilterPushDown, TableType},
    physical_expr::expressions::Column,
    physical_plan::{ExecutionPlan, PhysicalExpr, projection::ProjectionExec},
    prelude::{SessionContext, SQLOptions},
    sql::{parser::{DFParser, Statement}, sqlparser::ast::Statement as SqlStatement},
};
use policast_core::{model::FilterType, PolicyManifest};
use policast_datafusion::{cel_to_bool, cel_to_datafusion_expr, AttrIdentity, GovernedTable};

pub fn validate_sql(sql: &str) -> Result<()> {
    let statements = DFParser::parse_sql(sql)?;
    if statements.len() != 1 { bail!("QUERY_NOT_ALLOWED: exactly one SELECT/WITH query is required"); }
    match statements.front() {
        Some(Statement::Statement(s)) if matches!(s.as_ref(), SqlStatement::Query(_)) => Ok(()),
        _ => bail!("QUERY_NOT_ALLOWED: only SELECT/WITH queries are allowed"),
    }
}

pub async fn query(ctx: &SessionContext, sql: &str) -> Result<Vec<RecordBatch>> {
    validate_sql(sql)?;
    let options = SQLOptions::new().with_allow_ddl(false).with_allow_dml(false).with_allow_statements(false);
    Ok(ctx.sql_with_options(sql, options).await?.collect().await?)
}

// The pinned upstream provider forwards projection, filters and limit before
// applying its security expressions. For configurable SQL we instead expose a
// conservative outer boundary: govern the full scan, then project. User WHERE,
// aggregates and LIMIT stay in DataFusion above this boundary. This sacrifices
// pushdown deliberately; it is not an optimized production federation layer.
#[derive(Debug)]
pub struct ReadBoundary {
    governed: GovernedTable,
    manifest: PolicyManifest,
    identity: AttrIdentity,
    table_name: String,
}

impl ReadBoundary {
    pub fn new(source: Arc<dyn TableProvider>, manifest: PolicyManifest, table_name: &str, identity: AttrIdentity) -> Self {
        let governed = GovernedTable::new(source, manifest.clone(), table_name, identity.clone());
        Self { governed, manifest, identity, table_name: table_name.to_string() }
    }

    fn preflight(&self, state: &dyn Session) -> DFResult<()> {
        let schema = self.schema();
        let df_schema = DFSchema::try_from(schema.as_ref().clone())?;
        for p in &self.manifest.policies {
            if p.filter_type == FilterType::ColumnMask {
                let name = p.column.as_deref().ok_or_else(|| invalid("mask has no column"))?;
                let field = schema.field_with_name(name).map_err(|e| invalid(&e.to_string()))?;
                if !matches!(field.data_type(), DataType::Utf8 | DataType::LargeUtf8 | DataType::Utf8View) {
                    return Err(invalid("this Policast version supports string masking only"));
                }
                continue;
            }
            let expr = cel_to_datafusion_expr(&p.cel_expression, &self.identity)
                .map_err(|e| invalid(&format!("{}: {e}", p.id)))?;
            match expr {
                Some(expr) => {
                    let physical = state.create_physical_expr(expr, &df_schema)?;
                    if physical.data_type(schema.as_ref())? != DataType::Boolean {
                        return Err(invalid("row/deny predicate must be boolean"));
                    }
                }
                None => {
                    // Upstream interprets None as no filter. Never silently
                    // discard an unconditional deny or a non-boolean value.
                    if p.filter_type == FilterType::DenyOverride {
                        return Err(invalid("unconditional deny: query denied"));
                    }
                    if !cel_to_bool(&p.cel_expression, &self.identity, &self.table_name)
                        .map_err(|e| invalid(&e.to_string()))? {
                        return Err(invalid("row predicate did not evaluate to boolean true"));
                    }
                }
            }
        }
        Ok(())
    }
}

fn invalid(message: &str) -> DataFusionError {
    DataFusionError::Plan(format!("POLICY_INVALID: {message}"))
}

#[async_trait]
impl TableProvider for ReadBoundary {
    fn as_any(&self) -> &dyn Any { self }
    fn schema(&self) -> SchemaRef { self.governed.schema() }
    fn table_type(&self) -> TableType { self.governed.table_type() }
    fn supports_filters_pushdown(&self, filters: &[&Expr]) -> DFResult<Vec<TableProviderFilterPushDown>> {
        Ok(vec![TableProviderFilterPushDown::Unsupported; filters.len()])
    }
    async fn scan(&self, state: &dyn Session, projection: Option<&Vec<usize>>, _filters: &[Expr], _limit: Option<usize>) -> DFResult<Arc<dyn ExecutionPlan>> {
        self.preflight(state)?;
        let plan = self.governed.scan(state, None, &[], None).await?;
        let Some(indices) = projection else { return Ok(plan); };
        let schema = plan.schema();
        let mut expressions: Vec<(Arc<dyn PhysicalExpr>, String)> = Vec::new();
        for &index in indices {
            let field = schema.fields().get(index).ok_or_else(|| invalid("invalid projection index"))?;
            expressions.push((Arc::new(Column::new(field.name(), index)), field.name().clone()));
        }
        Ok(Arc::new(ProjectionExec::try_new(expressions, plan)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use datafusion::{arrow::{array::{Int64Array, StringArray}, datatypes::{Field, Schema}}, datasource::MemTable};
    use policast_core::parse_policies;

    fn session() -> SessionContext {
        let batch = RecordBatch::try_new(Arc::new(Schema::new(vec![
            Field::new("id", DataType::Int64, false), Field::new("tenant", DataType::Utf8, false),
            Field::new("secret", DataType::Utf8, false),
        ])), vec![Arc::new(Int64Array::from(vec![1,2,3])),
            Arc::new(StringArray::from(vec!["other", "one", "one"])),
            Arc::new(StringArray::from(vec!["x", "sensitive", "z"]))]).unwrap();
        let source = MemTable::try_new(batch.schema(), vec![vec![batch]]).unwrap();
        let cedar = r#"
@id("tenant") @target_table("records") @filter_type("row_filter")
permit(principal,action,resource) when { resource.tenant == principal.tenant };
@id("mask") @target_table("records") @filter_type("column_mask") @column("secret")
forbid(principal,action,resource) when { principal.role == "reader" };
"#;
        let mut m = PolicyManifest::new();
        m.compile_policies(&parse_policies(cedar).unwrap()).unwrap();
        let ctx = SessionContext::new();
        ctx.register_table("records", Arc::new(ReadBoundary::new(Arc::new(source), m, "records",
            AttrIdentity::new().with("tenant", "one").with("role", "reader")))).unwrap();
        ctx
    }
    #[test]
    fn rejects_writes_and_multiple_statements() {
        for sql in ["DELETE FROM records", "CREATE TABLE x AS SELECT 1", "COPY records TO '/tmp/x'", "SET x=1", "SELECT 1; SELECT 2"] {
            assert!(validate_sql(sql).is_err(), "{sql}");
        }
    }
    #[test]
    fn accepts_cte() { validate_sql("WITH x AS (SELECT 1) SELECT * FROM x").unwrap(); }
    #[tokio::test]
    async fn projection_can_omit_policy_columns() {
        let b = query(&session(), "SELECT id FROM records ORDER BY id").await.unwrap();
        let a = b[0].column(0).as_any().downcast_ref::<Int64Array>().unwrap();
        assert_eq!(a.values().as_ref(), &[2,3]);
    }
    #[tokio::test]
    async fn limit_is_after_row_security() {
        let b = query(&session(), "SELECT id FROM records LIMIT 1").await.unwrap();
        assert_eq!(b.iter().map(RecordBatch::num_rows).sum::<usize>(), 1);
        assert_eq!(b[0].column(0).as_any().downcast_ref::<Int64Array>().unwrap().value(0), 2);
    }
    #[tokio::test]
    async fn aggregate_sees_only_authorized_rows() {
        let b = query(&session(), "SELECT count(*) AS n FROM records").await.unwrap();
        assert_eq!(b[0].column(0).as_any().downcast_ref::<Int64Array>().unwrap().value(0), 2);
    }
    #[tokio::test]
    async fn predicate_cannot_probe_raw_masked_value() {
        let b = query(&session(), "SELECT id FROM records WHERE secret='sensitive'").await.unwrap();
        assert_eq!(b.iter().map(RecordBatch::num_rows).sum::<usize>(), 0);
    }
    #[tokio::test]
    async fn masked_predicate_sees_mask_value() {
        let b = query(&session(), "SELECT id FROM records WHERE secret='***'").await.unwrap();
        assert_eq!(b.iter().map(RecordBatch::num_rows).sum::<usize>(), 2);
    }
    #[tokio::test]
    async fn unregistered_table_fails() {
        assert!(query(&session(), "SELECT * FROM other_table").await.is_err());
    }
}
