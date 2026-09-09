from .harness import *

@case("CONC-01")
def conc_append(s):
    s.details["matrix"]=[s.concurrent_appends(n) for n in (2,4,8,16)]

@case("CONC-02")
def conc_tables(s):
    cat=s.init(); ws=[s.worker() for _ in range(8)]
    results=s.parallel([lambda i=i,w=w:s.write(cat,records([i]),table=f"t{i}",worker=w) for i,w in enumerate(ws)])
    for result in results:
        if isinstance(result,Exception): raise result
    for i in range(8):
        equal(s.query(cat,f"SELECT * FROM t{i}")["rows"],records([i]))

@case("CONC-03")
def conc_replace(s): s.conflict()

@case("CONC-04")
def conc_append_replace(s):
    cat=s.init(); s.write(cat,records([0])); a=s.worker(); b=s.worker()
    s.begin(a,cat,records([1]),"append"); s.begin(b,cat,records([2]))
    s.finish(b,cat)
    try:
        s.finish(a,cat)
    except OperationError as e:
        assert "conflict" in str(e).lower(), str(e)
        s.exact(cat,records([2])); return
    s.exact(cat,records([1,2]))
    limited("Observed stale append accepted after Replace. Exact serial order is Replace then Append; stale-write detection is not provided.")

@case("CONC-05")
def conc_pinned(s):
    cat=s.init(); snap=s.write(cat,records([0]))["snapshot"]
    reader=s.worker(); s.call("pin",cat,reader,token="old",snapshot=snap)
    ws=[s.worker(),s.worker()]
    for i,w in enumerate(ws): s.begin(w,cat,records([i+1]),"append")
    results=s.parallel([lambda w=w:s.finish(w,cat) for w in ws])
    for r in results:
        if isinstance(r,Exception): raise r
    equal(s.rows(cat,reader,token="old"),records([0])); s.exact(cat,records([0,1,2]))

@case("CONC-06")
def conc_abort(s):
    cat=s.init(); s.write(cat,records([0])); before=s.state(cat)["head"]
    for kill in (False,True):
        w=s.worker(); s.begin(w,cat,records([99]))
        if kill: w.crash()
        else: s.call("abort",cat,w,token="pending")
        w.close()
        s.exact(cat,records([0])); assert s.state(cat)["head"]==before,"abandoned write published snapshot"
    s.details["faults"]=["drop TableWriteSession", "SIGKILL independent writer container"]

@case("CONC-07")
def conc_stress(s):
    s.details["append_matrix"]=[]
    for n in (2,4,8):
        s.details["append_matrix"].append(s.concurrent_appends(n,50))
    s.details["replace_iterations_completed"]=0
    for i in range(50):
        s.conflict(f"_replace{i}")
        s.details["replace_iterations_completed"]+=1

@case("MW-01")
def mw_append(s):
    s.details["independent_processes"]=s.concurrent_appends(4,5)

@case("MW-02")
def mw_replace(s): s.conflict()

@case("MW-03")
def mw_head(s):
    cat=s.init(); s.write(cat,records([0])); ws=[s.worker() for _ in range(4)]
    previous=s.state(cat)["head"]; committed=[]; expected=records([0])
    for group in range(25):
        for i,w in enumerate(ws): s.begin(w,cat,records([1+4*group+i]),"append")
        # Reverse begin order deliberately tests commit order, not scheduling luck.
        for i in reversed(range(4)):
            r=s.finish(ws[i],cat); committed.append(r["snapshot"])
            expected+=records([1+4*group+i])
            assert r["snapshot"]>previous,"successful commits allocated non-monotonic snapshot ids"
            previous=r["snapshot"]
            state=s.state(cat); assert state["head"]==previous,"head is not latest successful commit"
            equal(s.rows(cat),expected)
    assert len(set(committed))==100
    for snap in committed:
        s.query(cat,snapshot=snap)
    s.exact(cat,expected)

@case("MW-04")
def mw_restart(s):
    cat=s.init(); w=s.worker(); s.write(cat,records([1]),worker=w); w.close()
    w=s.worker(); s.write(cat,records([2]),mode="append",worker=w); w.close()
    s.exact(cat,records([1,2]))

@case("MW-05")
def mw_timeout(s):
    cat=s.init(); s.write(cat,records([0])); locker=s.worker(); contender=s.worker()
    s.call("lock",cat,locker)
    start=time.monotonic()
    try:
        try:
            s.write(cat,records([1]),mode="append",worker=contender,timeout=50)
        except OperationError as e:
            elapsed=time.monotonic()-start
            assert any(x in str(e).lower() for x in ("lock timeout","lock_timeout","55p03")), str(e)
            assert elapsed<45,"lock wait was not bounded"
            s.details["lock_failure"]={"elapsed_seconds":elapsed,"error":str(e)}
        else: raise AssertionError("write bypassed held catalog lock")
    finally:
        s.call("unlock",cat,locker)
    s.write(cat,records([1]),mode="append",worker=contender)
    s.exact(cat,records([0,1]))

@case("MW-06")
def mw_catalogs(s):
    a=s.init("_a"); b=s.init("_b")
    ws=[s.worker(),s.worker()]
    results=s.parallel([lambda:s.write(a,records([1]),worker=ws[0]),lambda:s.write(b,records([2]),worker=ws[1])])
    for r in results:
        if isinstance(r,Exception): raise r
    s.exact(a,records([1])); s.exact(b,records([2]))
    fa={f["path"] for f in s.live_files(a)}; fb={f["path"] for f in s.live_files(b)}
    assert not (fa&fb),"physical file names overlap"
    objects=s.call("objects",a)["objects"]
    assert len({o["path"] for o in objects})==len(objects)
