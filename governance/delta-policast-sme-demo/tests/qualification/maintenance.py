from .harness import *

def maintenance_data(s):
    cat=s.init();old=s.write(cat,records([1]))["snapshot"]
    s.write(cat,records([2]));return cat,old

@case("MAINT-01")
def maint_expire(s):
    cat,old=maintenance_data(s);head=s.state(cat)["head"]
    r=s.call("expire",cat,snapshots=[old,head]);assert old in r["expired"] and head not in r["expired"]
    s.exact(cat,records([2]))

@case("MAINT-02")
def maint_dry(s):
    cat,old=maintenance_data(s);s.call("expire",cat,snapshots=[old])
    before=canonical(s.call("objects",cat)["objects"])
    dry=s.call("cleanup",cat,dry_run=True);assert dry["paths"],"dry run found no superseded files"
    assert canonical(s.call("objects",cat)["objects"])==before; s.exact(cat,records([2]))

@case("MAINT-03")
def maint_cleanup(s):
    cat,old=maintenance_data(s);s.call("expire",cat,snapshots=[old])
    before={o["path"] for o in s.call("objects",cat)["objects"]}
    paths={p.lstrip('/') for p in s.call("cleanup",cat,dry_run=True)["paths"]}
    assert paths and paths<=before
    s.call("cleanup",cat,dry_run=False)
    after={o["path"] for o in s.call("objects",cat)["objects"]}
    assert before-after==paths and not after-before,"cleanup removed unexpected objects"
    s.exact(cat,records([2]))

@case("MAINT-04")
def maint_orphans(s):
    cat=s.init();s.write(cat,records([1]));orphan=s.call("orphan",cat,token="injected")["path"]
    before={o["path"] for o in s.call("objects",cat)["objects"]}
    dry={p.lstrip('/') for p in s.call("orphans",cat,dry_run=True)["paths"]}
    assert orphan in dry;assert {o["path"] for o in s.call("objects",cat)["objects"]}==before
    removed={p.lstrip('/') for p in s.call("orphans",cat,dry_run=False)["paths"]}
    after={o["path"] for o in s.call("objects",cat)["objects"]}
    assert before-after==removed==dry; s.exact(cat,records([1]))

@case("MAINT-05")
def maint_idempotent(s):
    cat,old=maintenance_data(s);s.call("expire",cat,snapshots=[old]);s.call("cleanup",cat,dry_run=False)
    before=s.state(cat); assert not s.call("expire",cat,snapshots=[old])["expired"]
    assert not s.call("cleanup",cat,dry_run=False)["paths"]
    s.call("orphans",cat,dry_run=False);assert not s.call("orphans",cat,dry_run=False)["paths"]
    assert s.state(cat)==before;s.exact(cat,records([2]))


def compact_data(s,cat):
    s.write(cat,records([0]))
    for i in range(1,33):s.write(cat,records([i]),"append")
    assert len(s.live_files(cat))>=33

@case("MAINT-06")
def maint_compact(s):
    cat=s.init();compact_data(s,cat);before=len(s.live_files(cat))
    try:r=s.call("compact",cat,table="events")
    except OperationError as e:
        if not unsupported(e):raise
        s.exact(cat,records(range(33)));limited(str(e))
    assert r["processed"]>1 and len(s.live_files(cat))<before
    s.exact(cat,records(range(33)));s.details["compaction"]=r

@case("MAINT-07")
def maint_readers(s):
    cat=s.init();compact_data(s,cat);snapshot=s.state(cat)["head"]
    reader=s.worker();s.call("pin",cat,reader,token="before",snapshot=snapshot)
    writer=s.worker()
    try:
        with cf.ThreadPoolExecutor(max_workers=1) as pool:
            future=pool.submit(s.call,"compact",cat,writer,table="events")
            for _ in range(5):equal(s.rows(cat,reader,token="before"),records(range(33)))
            future.result(timeout=150)
    except OperationError as e:
        if not unsupported(e):raise
        s.exact(cat,records(range(33)));limited(str(e))
    equal(s.rows(cat,reader,token="before"),records(range(33)));s.exact(cat,records(range(33)))
