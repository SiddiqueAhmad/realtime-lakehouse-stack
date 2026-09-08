use anyhow::{Context, Result};

/// Only a successful query returning no row means "unknown principal".
/// Schema, connectivity, and other database errors still stop the request,
/// but retain their original SQLx cause instead of masquerading as a denial.
pub fn require_principal<T>(
    principal_key: &str,
    lookup: std::result::Result<Option<T>, sqlx::Error>,
) -> Result<T> {
    let row = lookup.with_context(|| {
        format!(
            "CONTROL_PLANE_ERROR: query principal {principal_key:?}; if the schema is outdated, apply postgres/migrations/001_dynamic_governance.sql"
        )
    })?;

    row.with_context(|| format!("ACCESS_DENIED: unknown principal {principal_key:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_principal_is_returned() {
        assert_eq!(require_principal("admin", Ok(Some(42))).unwrap(), 42);
    }

    #[test]
    fn absent_principal_is_access_denied() {
        let err = require_principal::<()>("hacker", Ok(None)).unwrap_err();
        assert_eq!(err.to_string(), "ACCESS_DENIED: unknown principal \"hacker\"");
    }

    #[test]
    fn column_error_is_not_unknown_principal() {
        let err = require_principal::<()>(
            "admin",
            Err(sqlx::Error::ColumnNotFound("attributes".to_string())),
        )
        .unwrap_err();
        assert!(err.to_string().starts_with("CONTROL_PLANE_ERROR:"));
        assert!(!err.to_string().contains("unknown principal"));
        assert!(format!("{err:#}").contains("attributes"));
        assert!(matches!(
            err.downcast_ref::<sqlx::Error>(),
            Some(sqlx::Error::ColumnNotFound(_))
        ));
    }

    #[test]
    fn connection_error_is_not_unknown_principal() {
        let err = require_principal::<()>("admin", Err(sqlx::Error::PoolTimedOut))
            .unwrap_err();
        assert!(err.to_string().starts_with("CONTROL_PLANE_ERROR:"));
        assert!(!err.to_string().contains("ACCESS_DENIED"));
        assert!(matches!(
            err.downcast_ref::<sqlx::Error>(),
            Some(sqlx::Error::PoolTimedOut)
        ));
    }
}
