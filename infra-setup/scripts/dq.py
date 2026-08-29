#!/usr/bin/env python3
"""
Ad-hoc DuckDB query helper for e2e-pipeline.yml — the DuckDB/DuckLake
equivalent of `trino --server ... --catalog iceberg --output-format
CSV_UNQUOTED --execute "..."` from the pre-migration version of this
workflow. Attaches the same two databases dbt itself attaches (see
warehouse/profiles.yml) and runs one query, printing one CSV line per
result row with no header — so existing `| tail -n1` call sites in the
workflow keep working unchanged.

Usage: dq.py "SELECT ..."

Connection details come from the same env vars warehouse/profiles.yml
reads (DUCKLAKE_CATALOG_*, RAW_CDC_*, DUCKLAKE_DATA_PATH), defaulting to
this repo's synthetic dev credentials so it works the same way locally and
in CI without extra setup.
"""

import os
import sys

import duckdb


def _dsn_parts(prefix: str, default_db: str) -> str:
    host = os.environ.get(f"{prefix}_HOST", "localhost")
    port = os.environ.get(f"{prefix}_PORT", "5433")
    user = os.environ.get(f"{prefix}_USER", "testuser")
    password = os.environ.get(f"{prefix}_PASSWORD", "testpass")
    dbname = os.environ.get(f"{prefix}_DB", default_db)
    return f"dbname={dbname} host={host} port={port} user={user} password={password}"


def connect() -> duckdb.DuckDBPyConnection:
    con = duckdb.connect()
    con.execute("INSTALL ducklake; LOAD ducklake;")
    con.execute("INSTALL postgres; LOAD postgres;")

    data_path = os.environ.get("DUCKLAKE_DATA_PATH", "/tmp/ducklake_data")
    catalog_dsn = _dsn_parts("DUCKLAKE_CATALOG", "warehouse")
    con.execute(f"ATTACH 'ducklake:postgres:{catalog_dsn}' AS lake (DATA_PATH '{data_path}/')")

    raw_dsn = _dsn_parts("RAW_CDC", "warehouse")
    con.execute(f"ATTACH '{raw_dsn}' AS raw (TYPE POSTGRES, READ_ONLY)")

    con.execute("USE lake")
    return con


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: dq.py \"SELECT ...\"", file=sys.stderr)
        return 2

    con = connect()
    rows = con.execute(sys.argv[1]).fetchall()
    # Deliberately unquoted, matching Trino's --output-format CSV_UNQUOTED:
    # several call sites in e2e-pipeline.yml build one comma-joined string
    # column on purpose (e.g. `count(*) || ',' || max_by(...)`) and compare
    # it against a literal "1,value" string — quoting a field just because
    # its *value* happens to contain a comma would break those comparisons.
    for row in rows:
        print(",".join("" if v is None else str(v) for v in row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
