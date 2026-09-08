use anyhow::{bail, Context, Result};
use std::collections::HashSet;

const USAGE: &str = "usage: governed-delta-demo PRINCIPAL --table TABLE_KEY [--table TABLE_KEY ...] (--sql SQL | --sql-file PATH) [--format pretty|json]";

pub struct Args {
    pub principal: String,
    pub tables: Vec<String>,
    pub sql: String,
    pub json: bool,
}

impl Args {
    pub fn parse(values: Vec<String>) -> Result<Self> {
        let mut args = values.into_iter();
        let principal = args.next().context(USAGE)?;
        if principal.trim().is_empty() || principal.starts_with('-') { bail!(USAGE); }
        let mut tables = Vec::new();
        let mut seen = HashSet::new();
        let mut sql = None;
        let mut json = false;
        while let Some(flag) = args.next() {
            let value = args.next().with_context(|| format!("missing value for {flag}; {USAGE}"))?;
            match flag.as_str() {
                "--table" => {
                    if value.trim().is_empty() || !seen.insert(value.clone()) {
                        bail!("table keys must be nonempty and unique");
                    }
                    tables.push(value);
                }
                "--sql" | "--sql-file" => {
                    if sql.is_some() { bail!("provide exactly one --sql or --sql-file"); }
                    sql = Some(if flag == "--sql-file" {
                        std::fs::read_to_string(&value).with_context(|| format!("read SQL file {value:?}"))?
                    } else { value });
                }
                "--format" => match value.as_str() {
                    "json" => json = true,
                    "pretty" => json = false,
                    _ => bail!("format must be pretty or json"),
                },
                _ => bail!("unknown option {flag:?}; {USAGE}"),
            }
        }
        if tables.is_empty() { bail!("at least one --table is required; {USAGE}"); }
        let sql = sql.context(USAGE)?;
        if sql.trim().is_empty() { bail!("SQL cannot be empty"); }
        Ok(Self { principal, tables, sql, json })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parse(s: &[&str]) -> Result<Args> { Args::parse(s.iter().map(|s| s.to_string()).collect()) }
    #[test]
    fn accepts_external_table_and_query() {
        let a = parse(&["alice", "--table", "ledger", "--sql", "SELECT * FROM ledger", "--format", "json"]).unwrap();
        assert_eq!(a.tables, vec!["ledger"]);
        assert!(a.json);
    }
    #[test]
    fn no_fixture_defaults() { assert!(parse(&["alice"]).is_err()); }
    #[test]
    fn rejects_duplicate_tables() {
        assert!(parse(&["alice", "--table", "t", "--table", "t", "--sql", "SELECT 1"]).is_err());
    }
    #[test]
    fn rejects_ambiguous_query_arguments() {
        assert!(parse(&["alice", "--table", "t", "--sql", "SELECT 1", "--sql", "SELECT 2"]).is_err());
    }
}
