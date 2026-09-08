// Governance control-plane UI. This binary manages identities, policies and bindings.
// It deliberately has no DataFusion/Delta/Iceberg imports and cannot query business data.
#[path = "../catalog.rs"]
mod catalog;
#[path = "../control_plane.rs"]
mod control_plane;
#[path = "../principal_lookup.rs"]
mod principal_lookup;

use std::{env, time::Duration};

use anyhow::{bail, Context, Result};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use policast_core::{model::{Effect, FilterType}, parse_policies, PolicyManifest};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use tokio::net::TcpListener;

const INDEX_HTML: &str = include_str!("../../ui/index.html");

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    http: Client,
    ai: Option<AiConfig>,
}

#[derive(Clone)]
struct AiConfig {
    chat_url: String,
    model: String,
    api_key: Option<String>,
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self { status: StatusCode::BAD_REQUEST, code: "INVALID_REQUEST", message: message.into() }
    }
    fn unprocessable(message: impl Into<String>) -> Self {
        Self { status: StatusCode::UNPROCESSABLE_ENTITY, code: "POLICY_INVALID", message: message.into() }
    }
    fn unavailable(message: impl Into<String>) -> Self {
        Self { status: StatusCode::SERVICE_UNAVAILABLE, code: "AI_NOT_CONFIGURED", message: message.into() }
    }
    fn internal(error: impl std::fmt::Display) -> Self {
        Self { status: StatusCode::INTERNAL_SERVER_ERROR, code: "INTERNAL_ERROR", message: error.to_string() }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.status, Json(json!({"code": self.code, "message": self.message}))).into_response()
    }
}

type ApiResult<T> = std::result::Result<T, ApiError>;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PolicyDraft {
    policy_key: String,
    binding_id: String,
    target: String,
    principal_selector: String,
    cedar: String,
    explanation: String,
}

#[derive(Debug, Serialize)]
struct DraftValidation {
    valid: bool,
    policy_id: String,
    filter_type: String,
    effect: String,
    target: String,
    column: Option<String>,
    required_attributes: Vec<String>,
    cel_expression: String,
}

#[derive(Debug, Deserialize)]
struct AiDraftRequest {
    rule: String,
    table_key: String,
    principal_selector: String,
}

#[derive(Debug, Deserialize)]
struct ApplyRequest {
    actor: String,
    #[serde(default = "default_source")]
    source: String,
    draft: PolicyDraft,
}

fn default_source() -> String { "ui".to_string() }

#[derive(Debug, Deserialize)]
struct EffectiveQuery {
    principal: String,
    table: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let pool = PgPoolOptions::new().max_connections(5).connect(&database_url).await
        .context("connect governance UI to Postgres")?;

    let ready = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM governance.schema_migrations WHERE version='004_control_plane_ui')"
    ).fetch_one(&pool).await
        .context("SCHEMA_MIGRATION_REQUIRED: run bash migrate.sh before starting governance-ui")?;
    if !ready { bail!("SCHEMA_MIGRATION_REQUIRED: run bash migrate.sh before starting governance-ui"); }

    let ai = match (env::var("AI_CHAT_URL").ok(), env::var("AI_MODEL").ok()) {
        (Some(chat_url), Some(model)) if !chat_url.trim().is_empty() && !model.trim().is_empty() => Some(AiConfig {
            chat_url,
            model,
            api_key: env::var("AI_API_KEY").ok().filter(|v| !v.trim().is_empty()),
        }),
        _ => None,
    };
    let http = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let state = AppState { pool, http, ai };

    let app = Router::new()
        .route("/", get(index))
        .route("/api/health", get(health))
        .route("/api/state", get(control_plane_state))
        .route("/api/effective", get(effective_access))
        .route("/api/policy/validate", post(validate_policy))
        .route("/api/policy/ai-draft", post(ai_draft))
        .route("/api/policy/apply", post(apply_policy))
        .with_state(state);

    let addr = env::var("GOVERNANCE_UI_ADDR").unwrap_or_else(|_| "0.0.0.0:8088".to_string());
    let listener = TcpListener::bind(&addr).await?;
    println!("Governance control plane UI listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn index() -> Html<&'static str> { Html(INDEX_HTML) }

async fn health(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    sqlx::query("SELECT 1").execute(&state.pool).await.map_err(ApiError::internal)?;
    Ok(Json(json!({"ok": true, "ai_configured": state.ai.is_some()})))
}

async fn control_plane_state(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let principal_rows = sqlx::query(
        "SELECT principal_key, role, display_name, attributes::text AS attributes_json FROM governance.principals ORDER BY principal_key"
    ).fetch_all(&state.pool).await.map_err(ApiError::internal)?;
    let principals: Vec<Value> = principal_rows.into_iter().map(|row| json!({
        "principal_key": row.get::<String,_>("principal_key"),
        "role": row.get::<String,_>("role"),
        "display_name": row.get::<Option<String>,_>("display_name"),
        "attributes": parse_json(&row.get::<String,_>("attributes_json")),
    })).collect();

    let policy_rows = sqlx::query(
        "SELECT policy_key, cedar, enabled, updated_at::text AS updated_at FROM governance.policies ORDER BY policy_key"
    ).fetch_all(&state.pool).await.map_err(ApiError::internal)?;
    let policies: Vec<Value> = policy_rows.into_iter().map(|row| json!({
        "policy_key": row.get::<String,_>("policy_key"),
        "cedar": row.get::<String,_>("cedar"),
        "enabled": row.get::<bool,_>("enabled"),
        "updated_at": row.get::<String,_>("updated_at"),
    })).collect();

    let binding_rows = sqlx::query(
        "SELECT binding_id, policy_key, target, principal_selector, precedence, enabled FROM governance.policy_bindings ORDER BY binding_id"
    ).fetch_all(&state.pool).await.map_err(ApiError::internal)?;
    let bindings: Vec<Value> = binding_rows.into_iter().map(|row| json!({
        "binding_id": row.get::<String,_>("binding_id"),
        "policy_key": row.get::<String,_>("policy_key"),
        "target": row.get::<String,_>("target"),
        "principal_selector": row.get::<String,_>("principal_selector"),
        "precedence": row.get::<i32,_>("precedence"),
        "enabled": row.get::<bool,_>("enabled"),
    })).collect();

    let table_rows = sqlx::query(
        "SELECT t.table_key, t.logical_name, t.location, t.enabled, t.config::text AS table_config, s.source_key, s.kind, s.enabled AS source_enabled, s.config::text AS source_config FROM governance.tables t JOIN governance.data_sources s ON s.source_key=t.source_key ORDER BY t.table_key"
    ).fetch_all(&state.pool).await.map_err(ApiError::internal)?;
    let tables: Vec<Value> = table_rows.into_iter().map(|row| json!({
        "table_key": row.get::<String,_>("table_key"),
        "logical_name": row.get::<String,_>("logical_name"),
        "location": row.get::<String,_>("location"),
        "enabled": row.get::<bool,_>("enabled"),
        "source_key": row.get::<String,_>("source_key"),
        "kind": row.get::<String,_>("kind"),
        "source_enabled": row.get::<bool,_>("source_enabled"),
        "table_config": parse_json(&row.get::<String,_>("table_config")),
        "source_config": parse_json(&row.get::<String,_>("source_config")),
    })).collect();

    let audit_rows = sqlx::query(
        "SELECT audit_id, entity_type, entity_key, action, actor, source, before_state::text AS before_state, after_state::text AS after_state, created_at::text AS created_at FROM governance.control_plane_audit ORDER BY audit_id DESC LIMIT 50"
    ).fetch_all(&state.pool).await.map_err(ApiError::internal)?;
    let audit: Vec<Value> = audit_rows.into_iter().map(|row| json!({
        "audit_id": row.get::<i64,_>("audit_id"),
        "entity_type": row.get::<String,_>("entity_type"),
        "entity_key": row.get::<String,_>("entity_key"),
        "action": row.get::<String,_>("action"),
        "actor": row.get::<String,_>("actor"),
        "source": row.get::<String,_>("source"),
        "before_state": row.get::<Option<String>,_>("before_state").map(|v| parse_json(&v)),
        "after_state": parse_json(&row.get::<String,_>("after_state")),
        "created_at": row.get::<String,_>("created_at"),
    })).collect();

    Ok(Json(json!({
        "ai_configured": state.ai.is_some(),
        "counts": {"principals": principals.len(), "policies": policies.len(), "bindings": bindings.len(), "tables": tables.len()},
        "principals": principals,
        "policies": policies,
        "bindings": bindings,
        "tables": tables,
        "audit": audit,
    })))
}

async fn effective_access(
    State(state): State<AppState>,
    Query(query): Query<EffectiveQuery>,
) -> ApiResult<Json<Value>> {
    let mut tx = state.pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    let principal = catalog::load_principal(&mut tx, &query.principal).await.map_err(|e| ApiError::unprocessable(e.to_string()))?;
    let table = catalog::load_table(&mut tx, &query.table).await.map_err(|e| ApiError::unprocessable(e.to_string()))?;
    let manifest = catalog::load_manifest(&mut tx, &query.principal, &principal.role, &table)
        .await.map_err(|e| ApiError::unprocessable(e.to_string()))?;
    control_plane::validate_principal_contract(&manifest, &query.principal, &principal.attributes)
        .map_err(|e| ApiError::unprocessable(e.to_string()))?;
    tx.commit().await.map_err(ApiError::internal)?;

    let required_attributes = manifest.principal_contract.as_ref()
        .map(|c| c.required_attributes.iter().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let policies: Vec<Value> = manifest.policies.iter().map(|policy| json!({
        "id": policy.id,
        "filter_type": format!("{:?}", policy.filter_type),
        "effect": format!("{:?}", policy.effect),
        "target": policy.target_table,
        "column": policy.column,
        "cel_expression": policy.cel_expression,
    })).collect();

    Ok(Json(json!({
        "principal": query.principal,
        "role": principal.role,
        "attributes": principal.attributes,
        "table": {"key": table.key, "logical_name": table.logical_name, "kind": table.kind},
        "required_attributes": required_attributes,
        "policies": policies,
        "note": "Policy resolution only. This control-plane UI does not query business data.",
    })))
}

async fn validate_policy(
    State(state): State<AppState>,
    Json(draft): Json<PolicyDraft>,
) -> ApiResult<Json<Value>> {
    ensure_table_exists(&state.pool, &draft.target).await?;
    let validation = validate_draft(&draft).map_err(|e| ApiError::unprocessable(e.to_string()))?;
    Ok(Json(json!({"draft": draft, "validation": validation})))
}

async fn ai_draft(
    State(state): State<AppState>,
    Json(input): Json<AiDraftRequest>,
) -> ApiResult<Json<Value>> {
    if input.rule.trim().len() < 8 {
        return Err(ApiError::bad_request("Describe one business access rule in more detail."));
    }
    ensure_table_exists(&state.pool, &input.table_key).await?;
    validate_selector(&input.principal_selector).map_err(|e| ApiError::bad_request(e.to_string()))?;
    let ai = state.ai.clone().ok_or_else(|| ApiError::unavailable(
        "Set AI_CHAT_URL and AI_MODEL to enable AI-assisted drafting. Manual Cedar validation remains available without AI."
    ))?;

    let system = r#"You are a governance policy drafting assistant. You are NOT the policy authority.
Return exactly one JSON object with these string fields: policy_key, binding_id, target, principal_selector, cedar, explanation.
Draft exactly ONE Cedar policy for the requested business rule. Assignment belongs only in principal_selector; never emit @roles or any policy assignment annotation.
Use target_table equal to the supplied table_key and @id equal to policy_key.
Supported patterns:
- row access: @filter_type(\"row_filter\") with permit(... action == Action::\"query\" ...) when { boolean expression };
- column masking: @filter_type(\"column_mask\") @column(\"column_name\") with forbid(... action == Action::\"query\" ...) when/unless { boolean expression };
- hard deny: @filter_type(\"deny_override\") with forbid(...) when/unless { boolean expression }.
Use only fields explicitly named in the user's rule. Supported expression operators are !, &&, ||, ==, !=, <, <=, >, >=, +, -, *, /, %. Do not use 'in', method calls, has(), nested object traversal, or invented fields.
A row_filter must be permit. A column_mask or deny_override must be forbid. Keep the explanation short and business-readable.
Do not activate or claim to activate the policy."#;
    let user = json!({
        "table_key": input.table_key,
        "principal_selector": input.principal_selector,
        "business_rule": input.rule,
    }).to_string();

    let body = json!({
        "model": ai.model,
        "temperature": 0.1,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
        ]
    });
    let mut request = state.http.post(&ai.chat_url).json(&body);
    if let Some(key) = &ai.api_key { request = request.bearer_auth(key); }
    let response = request.send().await.map_err(|e| ApiError::internal(format!("AI request failed: {e}")))?;
    let status = response.status();
    let response_body: Value = response.json().await.map_err(|e| ApiError::internal(format!("AI response was not JSON: {e}")))?;
    if !status.is_success() {
        return Err(ApiError::internal(format!("AI endpoint returned {status}: {response_body}")));
    }
    let content = response_body.pointer("/choices/0/message/content").and_then(Value::as_str)
        .ok_or_else(|| ApiError::internal("AI response missing choices[0].message.content"))?;
    let draft: PolicyDraft = serde_json::from_str(&strip_json_fence(content))
        .map_err(|e| ApiError::unprocessable(format!("AI draft was not the required policy JSON: {e}")))?;
    if draft.target != input.table_key || draft.principal_selector != input.principal_selector {
        return Err(ApiError::unprocessable("AI changed the requested target or principal selector; draft rejected."));
    }
    let validation = validate_draft(&draft).map_err(|e| ApiError::unprocessable(format!("AI draft failed deterministic validation: {e}")))?;
    Ok(Json(json!({"draft": draft, "validation": validation, "authority": "human approval required"})))
}

async fn apply_policy(
    State(state): State<AppState>,
    Json(input): Json<ApplyRequest>,
) -> ApiResult<Json<Value>> {
    if input.actor.trim().is_empty() || input.actor.len() > 128 {
        return Err(ApiError::bad_request("actor is required and must be 128 characters or fewer"));
    }
    if input.source.trim().is_empty() || input.source.len() > 64 {
        return Err(ApiError::bad_request("source must be 64 characters or fewer"));
    }
    ensure_table_exists(&state.pool, &input.draft.target).await?;
    let validation = validate_draft(&input.draft).map_err(|e| ApiError::unprocessable(e.to_string()))?;

    let mut tx = state.pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    let before_policy = sqlx::query_scalar::<_, String>(
        "SELECT to_jsonb(p)::text FROM governance.policies p WHERE policy_key=$1"
    ).bind(&input.draft.policy_key).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let before_binding = sqlx::query_scalar::<_, String>(
        "SELECT to_jsonb(b)::text FROM governance.policy_bindings b WHERE binding_id=$1"
    ).bind(&input.draft.binding_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;

    sqlx::query(
        "INSERT INTO governance.policies(policy_key, cedar, enabled, updated_at) VALUES ($1,$2,true,now()) ON CONFLICT(policy_key) DO UPDATE SET cedar=EXCLUDED.cedar, enabled=true, updated_at=now()"
    ).bind(&input.draft.policy_key).bind(&input.draft.cedar)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO governance.policy_bindings(binding_id,policy_key,target,principal_selector,precedence,enabled) VALUES ($1,$2,$3,$4,100,true) ON CONFLICT(binding_id) DO UPDATE SET policy_key=EXCLUDED.policy_key,target=EXCLUDED.target,principal_selector=EXCLUDED.principal_selector,precedence=EXCLUDED.precedence,enabled=true"
    ).bind(&input.draft.binding_id).bind(&input.draft.policy_key).bind(&input.draft.target).bind(&input.draft.principal_selector)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;

    let before = json!({
        "policy": before_policy.as_deref().map(parse_json),
        "binding": before_binding.as_deref().map(parse_json),
    });
    let after = json!({
        "policy": {"policy_key": input.draft.policy_key, "cedar": input.draft.cedar, "enabled": true},
        "binding": {"binding_id": input.draft.binding_id, "policy_key": input.draft.policy_key, "target": input.draft.target, "principal_selector": input.draft.principal_selector, "precedence": 100, "enabled": true},
        "explanation": input.draft.explanation,
    });
    let action = if before_policy.is_some() || before_binding.is_some() { "update" } else { "create" };
    sqlx::query(
        "INSERT INTO governance.control_plane_audit(entity_type,entity_key,action,actor,source,before_state,after_state) VALUES ('policy_bundle',$1,$2,$3,$4,$5::jsonb,$6::jsonb)"
    ).bind(&input.draft.policy_key).bind(action).bind(input.actor.trim()).bind(input.source.trim())
        .bind(before.to_string()).bind(after.to_string())
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    Ok(Json(json!({
        "applied": true,
        "action": action,
        "policy_key": input.draft.policy_key,
        "binding_id": input.draft.binding_id,
        "validation": validation,
        "message": "Policy and binding were deterministically validated, then applied by explicit human approval.",
    })))
}

async fn ensure_table_exists(pool: &PgPool, key: &str) -> ApiResult<()> {
    let exists = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM governance.tables t JOIN governance.data_sources s ON s.source_key=t.source_key WHERE t.table_key=$1 AND t.enabled AND s.enabled)"
    ).bind(key).fetch_one(pool).await.map_err(ApiError::internal)?;
    if !exists { return Err(ApiError::bad_request(format!("unknown or disabled table {key:?}"))); }
    Ok(())
}

fn validate_draft(draft: &PolicyDraft) -> Result<DraftValidation> {
    validate_identifier("policy_key", &draft.policy_key)?;
    validate_identifier("binding_id", &draft.binding_id)?;
    validate_identifier("target", &draft.target)?;
    validate_selector(&draft.principal_selector)?;
    if draft.explanation.trim().is_empty() { bail!("explanation is required"); }

    let parsed = parse_policies(&draft.cedar).context("parse Cedar")?;
    let mut manifest = PolicyManifest::new();
    manifest.compile_policies(&parsed).context("compile Cedar/CEL")?;
    if manifest.policies.len() != 1 { bail!("draft must contain exactly one policy"); }
    let policy = &manifest.policies[0];
    if policy.id != draft.policy_key { bail!("@id must equal policy_key"); }
    if policy.target_table != draft.target { bail!("@target_table must equal the selected target"); }
    if policy.is_tag_scoped() { bail!("tag-scoped policies are not supported by this control plane yet"); }
    if policy.applies_to.is_some() { bail!("policy assignment annotations are forbidden; use policy_bindings"); }
    if policy.filter_type == FilterType::RowFilter && policy.effect != Effect::Permit {
        bail!("row_filter must be a permit policy");
    }
    if policy.filter_type == FilterType::ColumnMask {
        if policy.effect != Effect::Forbid { bail!("column_mask must be a forbid policy"); }
        if policy.column.as_deref().map(str::trim).filter(|v| !v.is_empty()).is_none() {
            bail!("column_mask requires @column");
        }
    }
    if policy.filter_type == FilterType::DenyOverride && policy.effect != Effect::Forbid {
        bail!("deny_override must be a forbid policy");
    }
    let required_attributes = manifest.principal_contract.as_ref()
        .map(|contract| contract.required_attributes.iter().cloned().collect())
        .unwrap_or_default();
    Ok(DraftValidation {
        valid: true,
        policy_id: policy.id.clone(),
        filter_type: format!("{:?}", policy.filter_type),
        effect: format!("{:?}", policy.effect),
        target: policy.target_table.clone(),
        column: policy.column.clone(),
        required_attributes,
        cel_expression: policy.cel_expression.clone(),
    })
}

fn validate_identifier(kind: &str, value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 128 { bail!("{kind} must be 1-128 characters"); }
    let mut chars = value.chars();
    let first = chars.next().unwrap();
    if !(first.is_ascii_lowercase() || first == '_')
        || !chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
        bail!("{kind} must be a simple lowercase identifier");
    }
    Ok(())
}

fn validate_selector(selector: &str) -> Result<()> {
    if selector == "*" { return Ok(()); }
    let (kind, value) = selector.split_once(':').context("principal_selector must be *, role:<role>, or principal:<key>")?;
    if kind != "role" && kind != "principal" { bail!("principal_selector must use role: or principal:"); }
    if value.is_empty() || value.len() > 128
        || !value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.') {
        bail!("principal_selector value contains unsupported characters");
    }
    Ok(())
}

fn strip_json_fence(content: &str) -> String {
    let trimmed = content.trim();
    if !trimmed.starts_with("```") { return trimmed.to_string(); }
    let mut lines = trimmed.lines();
    lines.next();
    let mut body = lines.collect::<Vec<_>>();
    if body.last().map(|line| line.trim()) == Some("```") { body.pop(); }
    body.join("\n")
}

fn parse_json(raw: &str) -> Value {
    serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn region_draft() -> PolicyDraft {
        PolicyDraft {
            policy_key: "region_scope".into(),
            binding_id: "bind_region_scope".into(),
            target: "patients".into(),
            principal_selector: "role:analyst".into(),
            cedar: r#"@id("region_scope") @filter_type("row_filter") @target_table("patients") permit(principal, action == Action::"query", resource) when { resource.region == principal.region };"#.into(),
            explanation: "Analysts can read rows in their own region.".into(),
        }
    }

    #[test]
    fn valid_business_rule_compiles_and_derives_required_attribute() {
        let result = validate_draft(&region_draft()).unwrap();
        assert!(result.valid);
        assert!(result.required_attributes.iter().any(|v| v == "region"));
        assert_eq!(result.filter_type, "RowFilter");
    }

    #[test]
    fn target_mismatch_is_rejected() {
        let mut draft = region_draft();
        draft.target = "invoices".into();
        assert!(validate_draft(&draft).unwrap_err().to_string().contains("target_table"));
    }

    #[test]
    fn row_filter_cannot_be_a_forbid() {
        let mut draft = region_draft();
        draft.cedar = r#"@id("region_scope") @filter_type("row_filter") @target_table("patients") forbid(principal, action == Action::"query", resource) when { resource.region == principal.region };"#.into();
        // Policast may reject this invalid combination during compilation before
        // our explicit effect check runs. Either path is correct only if the
        // draft fails closed and can never reach Approve & Apply.
        assert!(validate_draft(&draft).is_err());
    }

    #[test]
    fn fenced_ai_json_is_normalized() {
        let raw = "```json\n{\"policy_key\":\"x\"}\n```";
        assert_eq!(strip_json_fence(raw), "{\"policy_key\":\"x\"}");
    }

    #[test]
    fn selectors_are_explicit_and_bounded() {
        for ok in ["*", "role:analyst", "principal:alice-1"] { validate_selector(ok).unwrap(); }
        for bad in ["group:finance", "role:", "role:bad/value"] { assert!(validate_selector(bad).is_err()); }
    }
}
