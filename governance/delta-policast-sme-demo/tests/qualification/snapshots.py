from .harness import *

@case("TT-01")
def tt_old(s):
    cat=s.init(); first=s.write(cat,records([1]))["snapshot"]
    s.write(cat,records([2]),"append")
    equal(s.rows(cat,snapshot=first),records([1])); s.exact(cat,records([1,2]))

@case("TT-02")
def tt_pin(s):
    cat=s.init(); snap=s.write(cat,records([1]))["snapshot"]
    w=s.worker(); s.call("pin",cat,w,token="old",snapshot=snap)
    for i in (2,3): s.write(cat,records([i]),"append")
    for _ in range(3): equal(s.rows(cat,w,token="old"),records([1]))
    s.exact(cat,records([1,2,3]))

@case("TT-03")
def tt_schema(s):
    cat=s.init(); old=records([1]); snap=s.write(cat,old)["snapshot"]
    fs=FIELDS+[{"name":"region","type":"string","nullable":True}]
    new=[{**old[0],"region":"east"}]; s.write(cat,new,fields=fs)
    result=s.query(cat,snapshot=snap)
    assert [f["name"] for f in result["schema"]]==[f["name"] for f in FIELDS],"historical snapshot returned CURRENT schema"
    equal(result["rows"],old); s.exact(cat,new)

@case("TT-04")
def tt_replaced(s):
    cat=s.init(); snap=s.write(cat,records([1,2]))["snapshot"]
    s.write(cat,records([2],value=99))
    equal(s.rows(cat,snapshot=snap),records([1,2])); s.exact(cat,records([2],value=99))

@case("TT-05")
def tt_expired(s):
    cat=s.init(); old=s.write(cat,records([1]))["snapshot"]
    s.write(cat,records([2])); s.call("expire",cat,snapshots=[old])
    assert old not in [x["snapshot_id"] for x in s.state(cat)["snapshots"]]
    try: result=s.query(cat,snapshot=old)
    except OperationError as e:
        assert any(x in str(e).lower() for x in ("snapshot","not found","missing")),str(e)
    else: raise AssertionError(f"expired snapshot accepted and returned {result['rows']}; must not look like a successful historical read")
    s.exact(cat,records([2]))

@case("TT-06")
def tt_sql(s):
    cat=s.init(); first=s.write(cat,records([1]))["snapshot"]
    s.write(cat,records([2]),"append")
    try: r=s.query(cat,f"SELECT * FROM events AT (VERSION => {first})")
    except OperationError as e:
        assert any(x in str(e).lower() for x in ("parser","expected","not implemented","not supported","unsupported")),str(e)
        s.exact(cat,records([1,2])); limited(f"SQL AT(VERSION) explicitly rejected: {e}")
    equal(r["rows"],records([1]))
