from .harness import *

@case("SCHEMA-01")
def schema_add(s):
    cat=s.init(); old=records([1]); s.write(cat,old)
    ids=s.columns(cat)
    fs=FIELDS+[{"name":"region","type":"string","nullable":True}]
    new=[{**records([2])[0],"region":"east"}]
    s.write(cat,new,"append",fields=fs)
    r=s.rows(cat)
    for x in r: x.setdefault("region",None)
    equal(r,[{**old[0],"region":None}]+new)
    current=s.columns(cat); assert all(current[k]==v for k,v in ids.items()),"field ids changed on add"
    fresh=s.worker(); r=s.rows(cat,fresh)
    for x in r:x.setdefault("region",None)
    equal(r,[{**old[0],"region":None}]+new)

@case("SCHEMA-02")
def schema_required(s):
    cat=s.init(); s.write(cat,records([1])); before=s.state(cat)["head"]
    fs=FIELDS+[{"name":"required_new","type":"string"}]
    try:s.write(cat,[{**records([2])[0],"required_new":"v"}],"append",fields=fs)
    except OperationError:
        s.exact(cat,records([1])); assert s.state(cat)["head"]==before; return
    raise AssertionError("required column without default was accepted while historical files lack it")

@case("SCHEMA-03")
def schema_drop(s):
    cat=s.init(); original=records([1,2]); s.write(cat,original)
    fs=[f for f in FIELDS if f["name"]!="value"]
    expected=[{k:v for k,v in r.items() if k!="value"} for r in original]
    s.write(cat,expected,fields=fs); s.exact(cat,expected)
    assert "value" not in s.columns(cat)

@case("SCHEMA-04")
def schema_rename(s):
    cat=s.init(); s.write(cat,records([1])); before=s.columns(cat)
    try:s.call("dml",cat,sql="ALTER TABLE events RENAME COLUMN value TO amount")
    except OperationError as e:
        if not unsupported(e):raise
        s.exact(cat,records([1])); assert s.columns(cat)==before
        limited(f"rename API/SQL unsupported in tested lane: {e}")
    expected=records([1]); expected[0]["amount"]=expected[0].pop("value")
    s.exact(cat,expected); assert s.columns(cat)["amount"]==before["value"]

@case("SCHEMA-05")
def schema_widen(s):
    cat=s.init(); fs=[dict(f) for f in FIELDS]; fs[0]["type"]="int32"
    s.write(cat,records([1]),fields=fs); before=s.columns(cat)
    try:s.call("promote",cat,table="events",column="id",type="int64")
    except OperationError as e:
        if not unsupported(e):raise
        s.exact(cat,records([1])); limited(str(e))
    s.write(cat,records([2**40]),"append")
    s.exact(cat,records([1,2**40])); assert s.columns(cat)["id"]==before["id"]
    assert s.query(cat)["schema"][0]["type"]=="Int64"

@case("SCHEMA-06")
def schema_narrow(s):
    cat=s.init(); old=records([2**40]); s.write(cat,old)
    before=s.state(cat)["head"]; fs=[dict(f) for f in FIELDS];fs[0]["type"]="int32"
    try:s.write(cat,records([1]),"append",fields=fs)
    except OperationError:
        s.exact(cat,old);assert s.state(cat)["head"]==before;return
    raise AssertionError("incompatible Int64->Int32 data-write schema accepted")

@case("SCHEMA-07")
def schema_governance(s):
    if s.lane=="df54":raise Outcome("BLOCKED","DF54 worker intentionally has no compatible Policast boundary")
    cat=s.init(); original=records([1]);s.write(cat,original)
    r=s.governed(cat)["rows"];assert r[0]["secret"]=="***"
    fs=[f for f in FIELDS if f["name"]!="tenant"]
    s.write(cat,[{k:v for k,v in original[0].items() if k!="tenant"}],fields=fs)
    try:s.governed(cat)
    except OperationError as e:
        assert "tenant" in str(e).lower(),str(e);return
    raise AssertionError("policy referencing removed tenant column did not fail closed")

@case("SCHEMA-08")
def schema_race(s):
    cat=s.init(); s.write(cat,records([0])); w=s.worker();s.begin(w,cat,records([1]),"append")
    fs=FIELDS+[{"name":"region","type":"string","nullable":True}]
    new=[{**records([2])[0],"region":"east"}];s.write(cat,new,fields=fs)
    try:s.finish(w,cat)
    except OperationError as e:
        assert any(x in str(e).lower() for x in ("conflict","schema")),str(e)
        s.exact(cat,new);return
    r=s.rows(cat)
    for row in r:row.setdefault("region",None)
    equal(r,new+[{**records([1])[0],"region":None}])
    assert "region" in s.columns(cat),"old append undid schema evolution"
