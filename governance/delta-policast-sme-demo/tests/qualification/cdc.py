from .harness import *

CDC_FIELDS = FIELDS + [{"name": "sequence", "type": "int64"}, {"name": "deleted", "type": "bool"}]


def change(row_id, sequence, value=0, deleted=False):
    return {**records([row_id], value=value)[0], "sequence": sequence, "deleted": deleted}


def materialize(s, cat, changes, worker=None):
    """Test-only single writer: sequence and tombstone live in DuckLake, not Python state.

    Full-state Replace is intentionally NOT claimed as a production CDC sink.
    """
    existing = s.rows(cat, worker)
    state = {row["id"]: row for row in existing}
    assert len(state) == len(existing), "duplicate keys in persisted materialization"
    dirty = False
    for event in changes:
        old = state.get(event["id"])
        if old is not None and event["sequence"] <= old["sequence"]:
            if event["sequence"] == old["sequence"]:
                assert event == old, "same source sequence has conflicting payload"
            continue
        state[event["id"]] = event; dirty = True
    if dirty:
        s.write(cat, list(state.values()), fields=CDC_FIELDS, worker=worker)
    return list(state.values())


@case("CDC-01")
def cdc_insert(s):
    cat=s.init(); s.write(cat,[change(1,1,10)],fields=CDC_FIELDS)
    expected=materialize(s,cat,[change(2,2,20)])
    s.exact(cat,expected)


@case("CDC-02")
def cdc_update(s):
    cat=s.init(); s.write(cat,records([1,2]))
    if s.lane=="df54":
        s.call("dml",cat,sql="UPDATE events SET value=222 WHERE id=2")
        s.exact(cat,records([1])+records([2],value=222))
    else:
        s.write(cat,[change(1,1,10),change(2,2,20)],fields=CDC_FIELDS)
        expected=materialize(s,cat,[change(2,3,222)])
        s.exact(cat,expected)
    s.details["mechanism"]="native UPDATE" if s.lane=="df54" else "test materializer: full-state Replace"


@case("CDC-03")
def cdc_delete(s):
    cat=s.init(); s.write(cat,records([1,2]))
    if s.lane=="df54":
        s.call("dml",cat,sql="DELETE FROM events WHERE id=2")
        s.exact(cat,records([1]))
    else:
        s.write(cat,[change(1,1,10),change(2,2,20)],fields=CDC_FIELDS)
        expected=materialize(s,cat,[change(2,3,20,True)])
        s.exact(cat,expected)
        equal(s.query(cat,"SELECT * FROM events WHERE deleted=false")["rows"],[change(1,1,10)])
    s.details["mechanism"]="native DELETE" if s.lane=="df54" else "test materializer with persisted tombstone"


@case("CDC-04")
def cdc_replay(s):
    cat=s.init(); s.write(cat,[change(1,1,10)],fields=CDC_FIELDS)
    events=[change(1,2,222),change(2,3,20,True)]
    once=materialize(s,cat,events); head=s.state(cat)["head"]
    twice=materialize(s,cat,events)
    equal(once,twice); s.exact(cat,once)
    assert s.state(cat)["head"]==head,"duplicate replay caused an unnecessary commit"


@case("CDC-05")
def cdc_atomic(s):
    cat=s.init(); old=records(range(25),value=0); new=records(range(25),value=1)
    s.write(cat,old); writer=s.worker(); reader=s.worker()
    s.begin(writer,cat,new)
    equal(s.rows(cat,reader),old,"prepared replacement became visible")
    observed=[]
    with cf.ThreadPoolExecutor(max_workers=1) as pool:
        future=pool.submit(s.finish,writer,cat)
        for _ in range(12):
            observed.append(s.rows(cat,reader))
        future.result(timeout=120)
    for rows in observed:
        assert canonical(rows) in (canonical(old),canonical(new)),"partial logical transaction observed"
    s.exact(cat,new); s.details["observations"]=len(observed)


@case("CDC-06")
def cdc_order(s):
    cat=s.init(); s.write(cat,[change(1,100,1)],fields=CDC_FIELDS)
    materialize(s,cat,[change(1,102,3,True)])
    materialize(s,cat,[change(1,101,2)])
    s.exact(cat,[change(1,102,3,True)])
    s.details["scope"]="stale events ignored by test materializer using persisted sequence/tombstone; NOT a native CDC guarantee"


@case("CDC-07")
def cdc_restart(s):
    cat=s.init(); s.write(cat,[change(1,1,10)],fields=CDC_FIELDS)
    events=[change(1,2,11),change(2,3,99,True)]; materialize(s,cat,events)
    w=s.worker()
    try:
        expected=materialize(s,cat,events,w)
    finally:
        w.close()
    s.exact(cat,expected)


