use std::{any::Any, sync::Arc};
use anyhow::{bail, Result};
use async_trait::async_trait;
use datafusion::{
    arrow::{datatypes::{DataType, SchemaRef}, record_batch::RecordBatch},
    catalog::Session,
    common::{DataFusionError, DFSchema, Result as DFResult},
    datasource::TableProvider,
    logical_expr::{expr_fn::cast, Expr, TableProviderFilterPushDown, TableType},
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
                if !is_string(field.data_type()) {
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

fn is_string(data_type: &DataType) -> bool {
    matches!(data_type, DataType::Utf8 | DataType::LargeUtf8 | DataType::Utf8View)
}

/// Reconcile the physical string layout AFTER masking, without accessing the
/// raw provider. The pinned Policast mask emits Utf8 literals even when the
/// provider advertises Utf8View/LargeUtf8. Downstream expressions are planned
/// against the advertised schema, so simply returning that plan causes an
/// Arrow Utf8/Utf8View comparison error. Convert only between string layouts;
/// unexpected non-string type/name/arity changes are hard errors.
fn align_governed_strings(
    state: &dyn Session,
    plan: Arc<dyn ExecutionPlan>,
    declared: &SchemaRef,
) -> DFResult<Arc<dyn ExecutionPlan>> {
    let actual = plan.schema();
    if actual.fields().len() != declared.fields().len() {
        return Err(invalid("governed output changed the number of columns"));
    }
    let mut needs_cast = false;
    for (source, target) in actual.fields().iter().zip(declared.fields()) {
        if source.name() != target.name() {
            return Err(invalid("governed output changed column names/order"));
        }
        if source.data_type() != target.data_type() {
            if !is_string(source.data_type()) || !is_string(target.data_type()) {
                return Err(invalid("unexpected non-string governed output type change"));
            }
            needs_cast = true;
        }
    }
    if !needs_cast { return Ok(plan); }

    let df_schema = DFSchema::try_from(actual.as_ref().clone())?;
    let mut expressions: Vec<(Arc<dyn PhysicalExpr>, String)> = Vec::new();
    for (index, (source, target)) in actual.fields().iter().zip(declared.fields()).enumerate() {
        let expression: Arc<dyn PhysicalExpr> = if source.data_type() == target.data_type() {
            Arc::new(Column::new(source.name(), index))
        } else {
            // Use an unqualified column object, not SQL parsing of the name.
            let column = Expr::Column(datafusion::common::Column::new_unqualified(source.name()));
            state.create_physical_expr(cast(column, target.data_type().clone()), &df_schema)?
        };
        expressions.push((expression, target.name().clone()));
    }
    Ok(Arc::new(ProjectionExec::try_new(expressions, plan)?))
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
        let plan = align_governed_strings(state, plan, &self.schema())?;
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
    use datafusion::{arrow::{array::{ArrayRef, Int64Array, StringArray}, compute::cast as arrow_cast, datatypes::{Field, Schema}}, datasource::MemTable};
    use policast_core::parse_policies;

    fn session() -> SessionContext { session_with_string_type(DataType::Utf8) }

    fn session_with_string_type(string_type: DataType) -> SessionContext {
        let tenant: ArrayRef = Arc::new(StringArray::from(vec!["other", "one", "one"]));
        let secret: ArrayRef = Arc::new(StringArray::from(vec!["x", "sensitive", "z"]));
        let batch = RecordBatch::try_new(Arc::new(Schema::new(vec![
            Field::new("id", DataType::Int64, false), Field::new("tenant", string_type.clone(), false),
            Field::new("secret", string_type.clone(), false),
        ])), vec![Arc::new(Int64Array::from(vec![1,2,3])),
            arrow_cast(tenant.as_ref(), &string_type).unwrap(),
            arrow_cast(secret.as_ref(), &string_type).unwrap()]).unwrap();
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
    #[tokio::test]
    async fn utf8_view_mask_preserves_declared_output_type() {
        let b = query(&session_with_string_type(DataType::Utf8View), "SELECT secret FROM records ORDER BY id").await.unwrap();
        assert_eq!(b.iter().map(RecordBatch::num_rows).sum::<usize>(), 2);
        for batch in b {
            assert_eq!(batch.column(0).data_type(), &DataType::Utf8View);
            let strings = arrow_cast(batch.column(0).as_ref(), &DataType::Utf8).unwrap();
            let strings = strings.as_any().downcast_ref::<StringArray>().unwrap();
            assert!(strings.iter().all(|value| value == Some("***")));
        }
    }
    #[tokio::test]
    async fn utf8_view_predicates_see_masks_not_raw_values() {
        let ctx = session_with_string_type(DataType::Utf8View);
        let raw = query(&ctx, "SELECT id FROM records WHERE secret='sensitive'").await.unwrap();
        assert_eq!(raw.iter().map(RecordBatch::num_rows).sum::<usize>(), 0);
        let masked = query(&ctx, "SELECT id FROM records WHERE secret='***'").await.unwrap();
        assert_eq!(masked.iter().map(RecordBatch::num_rows).sum::<usize>(), 2);
    }
    #[tokio::test]
    async fn large_utf8_mask_preserves_type_and_predicate_semantics() {
        let ctx = session_with_string_type(DataType::LargeUtf8);
        let masked = query(&ctx, "SELECT secret FROM records WHERE secret='***'").await.unwrap();
        assert_eq!(masked.iter().map(RecordBatch::num_rows).sum::<usize>(), 2);
        for batch in masked {
            assert_eq!(batch.column(0).data_type(), &DataType::LargeUtf8);
        }
        let raw = query(&ctx, "SELECT id FROM records WHERE secret='sensitive'").await.unwrap();
        assert_eq!(raw.iter().map(RecordBatch::num_rows).sum::<usize>(), 0);
    }
}
