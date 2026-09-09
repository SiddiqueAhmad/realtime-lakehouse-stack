#!/usr/bin/env python3
"""Black-box governance tests against Delta, Iceberg v3, or DuckLake."""
from __future__ import annotations
import json
import os
import subprocess
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ["docker", "compose", "-f", str(ROOT / "docker-compose.yml")]
TABLE_FORMAT = os.environ.get("TABLE_FORMAT", "delta").lower()
if TABLE_FORMAT not in {"delta", "iceberg", "ducklake"}:
    raise SystemExit("TABLE_FORMAT must be delta, iceberg, or ducklake")


def run(args: list[str], text: str | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(COMPOSE + args, input=text, capture_output=True, text=True, cwd=ROOT)
    if check and result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}\n{result.stderr}")
    return result


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> None:
    suffix = uuid.uuid4().hex[:12]
    database = f"governance_e2e_{TABLE_FORMAT}_{suffix}"
    prefix = f"s3://lake/_governance_tests/{TABLE_FORMAT}/{suffix}"
    created = False
    passed = 0
    db_url = f"postgresql://governance:governance@postgres:5432/{database}"
    iceberg_catalog = f"e2e_{suffix}"
    iceberg_warehouse = f"{prefix}/warehouse"
    ducklake_catalog = f"e2e_{suffix}"
    ducklake_data_path = f"{prefix}/warehouse"

    def pg(sql: str, db: str = database) -> str:
        return run(["exec", "-T", "postgres", "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "governance", "-d", db, "-At"], sql).stdout

    def check(condition: bool, message: str) -> None:
        if not condition:
            raise AssertionError(message)

    def passed_case(name: str) -> None:
        nonlocal passed
        passed += 1
        print(f"PASS {passed}: {name}", flush=True)

    def invoke(principal: str, sql: str, tables: tuple[str, ...] = ("patients",)) -> subprocess.CompletedProcess[str]:
        args = ["run", "--rm", "-T", "--no-deps", "-e", f"DATABASE_URL={db_url}",
                "governed-query", principal]
        for key in tables:
            args += ["--table", key]
        return run(args + ["--sql", sql, "--format", "json"], check=False)

    def query(principal: str, sql: str = "SELECT * FROM patients ORDER BY patient_id", tables: tuple[str, ...] = ("patients",)) -> list[dict]:
        result = invoke(principal, sql, tables)
        check(result.returncode == 0, f"query failed:\n{result.stdout}\n{result.stderr}")
        rows = json.loads(result.stdout)
        check(isinstance(rows, list), "result is not a JSON array")
        return rows

    def denied(principal: str, needle: str, sql: str = "SELECT * FROM patients", tables: tuple[str, ...] = ("patients",)) -> None:
        result = invoke(principal, sql, tables)
        check(result.returncode != 0, "denied query unexpectedly succeeded")
        check(not result.stdout.strip(), f"failure emitted result data: {result.stdout}")
        check(needle in result.stderr, f"missing error {needle!r}: {result.stderr}")

    fixture = json.loads((ROOT / "fixtures/healthcare/table.json").read_text())
    by_id = {r["patient_id"]: r for r in fixture["rows"]}

    def expected(ids: list[str], masked: bool = False) -> list[dict]:
        rows = [dict(by_id[key]) for key in ids]
        if masked:
            for row in rows:
                row["ssn"] = row["diagnosis"] = "***"
        return rows

    def policy(expression: str, target: str = "patients") -> str:
        return (f'@id("row_filter_region") @filter_type("row_filter") @target_table("{target}") '
                f'permit(principal,action == Action::"query",resource) when {{ {expression} }};')

    def set_policy(source: str) -> None:
        pg(f"UPDATE governance.policies SET cedar={quote(source)} WHERE policy_key='row_filter_region';")

    def configure_and_seed(scenario: str, table: str) -> None:
        location = f"{prefix}/{table}"
        if TABLE_FORMAT == "delta":
            pg(f"UPDATE governance.tables SET location={quote(location)} WHERE table_key={quote(table)};")
            run(["run", "--rm", "-T", "--no-deps", "fixture-loader",
                 f"/fixtures/{scenario}/table.json", location])
            return

        if TABLE_FORMAT == "iceberg":
            namespace = scenario
            config = json.dumps({"namespace": namespace, "table": table}, separators=(",", ":"))
            pg(f"UPDATE governance.tables SET source_key='demo-iceberg', location={quote(location)}, config={quote(config)}::jsonb WHERE table_key={quote(table)};")
            seeded = run([
                "run", "--rm", "-T", "--no-deps",
                "-e", f"DATABASE_URL={db_url}",
                "-e", f"ICEBERG_CATALOG_NAME={iceberg_catalog}",
                "-e", f"ICEBERG_WAREHOUSE={iceberg_warehouse}",
                "iceberg-fixture-loader", f"/fixtures/{scenario}/table.json",
                namespace, table, location,
            ])
            check("format-version=3" in seeded.stdout, f"fixture was not verified as Iceberg v3: {seeded.stdout}")
            return

        config = json.dumps({"schema": scenario, "table": table}, separators=(",", ":"))
        pg(f"UPDATE governance.tables SET source_key='demo-ducklake', location={quote(location)}, config={quote(config)}::jsonb WHERE table_key={quote(table)};")
        seeded = run([
            "run", "--rm", "-T", "--no-deps",
            "-e", f"DATABASE_URL={db_url}",
            "ducklake-fixture-loader", f"/fixtures/{scenario}/table.json",
            ducklake_catalog, scenario, table, ducklake_data_path,
        ])
        check("Seeded DuckLake" in seeded.stdout, f"DuckLake fixture load failed: {seeded.stdout}")

    baseline = policy("resource.region == principal.region")
    try:
        pg(f'CREATE DATABASE "{database}";', "postgres")
        created = True
        pg((ROOT / "postgres/init.sql").read_text())
        for migration in sorted((ROOT / "postgres/migrations").glob("*.sql")):
            pg(migration.read_text())
        for scenario in ["healthcare", "trading"]:
            pg((ROOT / f"fixtures/{scenario}/governance.sql").read_text())

        if TABLE_FORMAT == "iceberg":
            source_config = json.dumps({"catalog_name": iceberg_catalog, "warehouse": iceberg_warehouse}, separators=(",", ":"))
            pg(f"INSERT INTO governance.data_sources(source_key,kind,config) VALUES ('demo-iceberg','iceberg_sql',{quote(source_config)}::jsonb) ON CONFLICT (source_key) DO UPDATE SET kind=EXCLUDED.kind, config=EXCLUDED.config, enabled=true;")
        elif TABLE_FORMAT == "ducklake":
            source_config = json.dumps({"catalog_name": ducklake_catalog}, separators=(",", ":"))
            pg(f"INSERT INTO governance.data_sources(source_key,kind,config) VALUES ('demo-ducklake','ducklake_postgres',{quote(source_config)}::jsonb) ON CONFLICT (source_key) DO UPDATE SET kind=EXCLUDED.kind, config=EXCLUDED.config, enabled=true;")

        configure_and_seed("healthcare", "patients")
        configure_and_seed("trading", "invoices")

        check(query("admin") == expected(["1001", "1002", "1003", "1004", "1006"]), "admin rows/columns mismatch")
        passed_case("admin exact rows, unmasked values, legal hold excluded")
        check(query("physician") == expected(["1001", "1003"]), "physician rows/columns mismatch")
        passed_case("physician exact own-patient rows")
        check(query("analyst") == expected(["1001", "1003", "1006"], True), "analyst masks/rows mismatch")
        passed_case("analyst exact regional rows and every sensitive value masked")
        denied("hacker", "ACCESS_DENIED")
        passed_case("unknown principal: nonzero exit, no result data")

        set_policy("this is invalid cedar")
        denied("analyst", "parse Cedar policy row_filter_region")
        set_policy(baseline)
        passed_case("malformed policy fails closed")
        pg("UPDATE governance.principals SET attributes=jsonb_set(attributes,'{region}','\"us-west\"') WHERE principal_key='analyst';")
        check(query("analyst") == expected(["1002"], True), "hot region change/deny mismatch")
        passed_case("runtime region change, including legal-hold exclusion in same region")
        pg("UPDATE governance.principals SET attributes=attributes || '{\"doctor_scope\":\"Dr. Smith\"}'::jsonb WHERE principal_key='analyst';")
        set_policy(policy("resource.treating_physician == principal.doctor_scope"))
        check(query("analyst") == expected(["1001", "1003"], True), "new dynamic attribute mismatch")
        passed_case("new attribute and different column filter without rebuilding")
        pg("UPDATE governance.principals SET attributes=attributes-'doctor_scope' WHERE principal_key='analyst';")
        denied("analyst", "doctor_scope")
        set_policy(baseline)
        pg("UPDATE governance.principals SET attributes=jsonb_set(attributes,'{region}','\"us-east\"') WHERE principal_key='analyst';")
        passed_case("missing dynamic attribute fails closed")

        invoices = query("finance_reader", "SELECT * FROM invoices ORDER BY invoice_id", ("invoices",))
        check([r["invoice_id"] for r in invoices] == ["INV-001", "INV-004"], "invoice scope mismatch")
        check(all(r["bank_account"] == "***" for r in invoices), "invoice mask mismatch")
        passed_case("same binary with unrelated invoices schema and company/branch policies")
        check(query("finance_reader", "SELECT invoice_id, amount_minor FROM invoices WHERE status='OPEN' ORDER BY invoice_id", ("invoices",)) == [{"invoice_id":"INV-001", "amount_minor":120000}], "arbitrary invoice query mismatch")
        passed_case("caller SQL filters/projects arbitrary columns")
        check(query("analyst", "SELECT patient_id FROM patients ORDER BY patient_id LIMIT 2") == [{"patient_id":"1001"}, {"patient_id":"1003"}], "projection/limit weakened governance")
        passed_case("projection omits policy columns; limit applies after governance")
        check(query("analyst", "SELECT COUNT(*) AS n FROM patients") == [{"n":3}], "aggregate leaked row count")
        passed_case("aggregate counts only authorized rows")
        check(query("analyst", "SELECT patient_id FROM patients WHERE ssn='123-45-6789'") == [], "user predicate probed raw masked data")
        passed_case("user predicate cannot probe original masked values")
        check(query("analyst", "WITH x AS (SELECT patient_id FROM patients) SELECT * FROM x ORDER BY patient_id") == [{"patient_id":k} for k in ["1001","1003","1006"]], "CTE scope mismatch")
        passed_case("CTE uses the same governed provider")

        pg("INSERT INTO governance.principals(principal_key,role,attributes) VALUES ('reviewer','auditor','{\"region\":\"us-east\"}');")
        denied("reviewer", "no bound permit row policy")
        pg("INSERT INTO governance.policy_bindings(binding_id,policy_key,target,principal_selector) VALUES ('test_role','row_filter_region','patients','role:auditor');")
        check(query("reviewer") == expected(["1001","1003","1006"], True), "role binding mismatch")
        pg("UPDATE governance.policy_bindings SET principal_selector='principal:reviewer' WHERE binding_id='test_role'; UPDATE governance.principals SET role='other_role' WHERE principal_key='reviewer';")
        check(query("reviewer") == expected(["1001","1003","1006"], True), "principal binding mismatch")
        pg("UPDATE governance.policy_bindings SET enabled=false WHERE binding_id='test_role';")
        denied("reviewer", "no bound permit row policy")
        passed_case("role/principal bindings are dynamic; global masks are not access grants")

        set_policy(policy("resource.no_such_column == principal.region"))
        denied("analyst", "no_such_column")
        set_policy(policy("resource.region == principal.region", "another_table"))
        denied("analyst", "binding and Cedar target disagree")
        set_policy(baseline)
        passed_case("invalid schema references and binding/target mismatches fail closed")
        set_policy(policy('["us-east","us-west"].contains(resource.region)'))
        result = invoke("analyst", "SELECT * FROM patients")
        check(result.returncode != 0 and not result.stdout.strip(), "unsupported expression was silently skipped")
        set_policy(baseline)
        passed_case("unsupported policy expression does not silently remove the filter")

        for sql in ["DELETE FROM patients", "CREATE TABLE copied AS SELECT * FROM patients", "COPY patients TO '/tmp/leak.parquet'", "SET x=1", "SELECT * FROM patients; SELECT 1"]:
            denied("analyst", "QUERY_NOT_ALLOWED", sql)
        passed_case("DDL, DML, COPY, session changes and multiple statements rejected")
        denied("analyst", "unknown or disabled table", tables=("unregistered",))
        pg("UPDATE governance.tables SET enabled=false WHERE table_key='patients';")
        denied("analyst", "unknown or disabled table")
        pg("UPDATE governance.tables SET enabled=true WHERE table_key='patients';")
        passed_case("unregistered/disabled tables are not exposed")
        denied("analyst", "no bound permit row policy", "SELECT * FROM invoices", ("patients", "invoices"))
        passed_case("each requested table must be independently authorized")
        print(f"PASS: {passed} governance regression cases on {TABLE_FORMAT}", flush=True)
    finally:
        if created:
            # Only the unique scratch database is removed, never governance.
            pg(f'DROP DATABASE "{database}" WITH (FORCE);', "postgres")
        print(f"Isolated {TABLE_FORMAT} fixture objects retained at {prefix}", flush=True)


if __name__ == "__main__":
    main()
