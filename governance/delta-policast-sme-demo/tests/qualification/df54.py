from .harness import *
from .performance import perf_partition
from .maintenance import maint_compact

@case("DF54-01")
def df54_build(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    hello=s.main.call("hello");assert hello["lane"]=="df54"
    s.details["native_execution"]=hello

@case("DF54-02")
def df54_fixtures(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    cat=s.init()
    for scenario,table in (("healthcare","patients"),("trading","invoices")):
        fixture=json.loads((ROOT/f"fixtures/{scenario}/table.json").read_text())
        s.write(cat,fixture["rows"],fields=fixture["fields"],table=table)
        equal(s.query(cat,f"SELECT * FROM {table}")["rows"],fixture["rows"])
    s.details["scope"]="raw fixture IO, not governed parity"

@case("DF54-03")
def df54_dml(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    cat=s.init();s.write(cat,records([1,2,3]))
    s.call("dml",cat,sql="UPDATE events SET value=value+100 WHERE id IN (1,2)")
    expected=records([1,2,3]);expected[0]["value"]+=100;expected[1]["value"]+=100
    s.exact(cat,expected)
    s.call("dml",cat,sql="DELETE FROM events WHERE id=2");s.exact(cat,[expected[0],expected[2]])

@case("DF54-04")
def df54_maintenance(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    perf_partition(s)
    old_case=s.current_case;s.current_case+="_compact"
    try:maint_compact(s)
    finally:s.current_case=old_case

@case("DF54-05")
def df54_policast(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    app=(s.output/"governed-app-Cargo.toml").read_text()
    assert 'datafusion = "=53.1.0"' in app,"production dependency changed; implement and execute governance compatibility before removing this gate"
    cat=s.init();s.write(cat,records([1]))
    try:s.governed(cat)
    except OperationError as e:
        assert "UNSUPPORTED" in str(e) and "Policast" in str(e)
        limited("DF54 governed entry point explicitly refuses access; production Policast dependency still DF53")
    raise AssertionError("DF54 unexpectedly accepted governed query without compatibility proof")

@case("DF54-06")
def df54_dependencies(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    packages=s.graph["packages"]
    family={p["name"]:p["version"] for p in packages if p["name"]=="datafusion" or (p["name"].startswith("datafusion-") and p["name"]!="datafusion-ducklake")}
    assert family and set(family.values())=={"54.1.0"},f"incoherent DataFusion release family: {family}"
    assert not any(p["name"] in ("duckdb","libduckdb-sys","policast-datafusion") for p in packages),"unexpected runtime dependency"
    s.details["datafusion_family"]=family

@case("DF54-07")
def df54_governance_gate(s):
    if s.lane!="df54":raise Outcome("NOT_APPLICABLE","DF54-only case")
    names={p["name"] for p in s.graph["packages"]}
    if "policast-datafusion" not in names:
        raise Outcome("BLOCKED","the unchanged 20-case governed suite cannot execute on a raw-only DF54 worker; no parity claim")
    raise AssertionError("Policast appeared in DF54 graph: wire the actual 20-case runner, do not convert this gate into PASS")
