from .harness import *
import math

def perf_data(s,files=16):
    cat=s.init();s.write(cat,records(range(128)))
    for i in range(1,files):s.write(cat,records(range(i*128,(i+1)*128)),"append")
    return cat

@case("PERF-01")
def perf_filter(s):
    cat=perf_data(s);full=s.query(cat);filtered=s.query(cat,"SELECT * FROM events WHERE id=129")
    equal(full["rows"],records(range(2048)));equal(filtered["rows"],records([129]))
    s.details.update(full={k:v for k,v in full.items() if k!="rows"},selective=filtered)
    raise Outcome("METRIC","unpartitioned selective scan; actual object IO and plan captured")

@case("PERF-02")
def perf_partition(s):
    cat=s.init();s.write(cat,[])
    # The DuckLake DDL wrapper resolves unqualified names in 'main', independently
    # of DataFusion's default schema. Our fixture is in 'public': qualify it.
    try:s.call("dml",cat,sql="ALTER TABLE lake.public.events SET PARTITIONED BY (tenant)")
    except OperationError as e:
        if not (unsupported(e) or "parser" in str(e).lower() or "expected" in str(e).lower()):raise
        limited(f"partition DDL unavailable in this lane: {e}")
    expected=[r for i in range(16) for r in records(range(i*128,(i+1)*128),tenant=f"t{i}")]
    s.write(cat,expected)
    files=s.live_files(cat); assert len(files)>=16 and all(f.get("partition_id") is not None for f in files),"writer did not produce partition metadata/files"
    full=s.query(cat);filtered=s.query(cat,"SELECT * FROM events WHERE tenant='t5' ORDER BY id")
    equal(full["rows"],expected);equal(filtered["rows"],[r for r in expected if r["tenant"]=="t5"])
    assert 0<filtered["io"]["distinct_objects_read"]<full["io"]["distinct_objects_read"],"partitioned selective query did not prune physical object reads"
    s.details.update(full_io=full["io"],selective_io=filtered["io"],plan=filtered["plan"])

@case("PERF-03")
def perf_stats(s):
    cat=perf_data(s);full=s.query(cat);r=s.query(cat,"SELECT * FROM events WHERE id=129")
    equal(full["rows"],records(range(2048)));equal(r["rows"],records([129]))
    # A nonzero pruning timer is NOT proof that anything was pruned.
    pruned=sum(v for k,v in r["metrics"].items() if k.endswith("_pruned") and "time" not in k)
    assert pruned>0 or r["io"]["response_range_bytes"]<full["io"]["response_range_bytes"],"no physical statistics-pruning evidence"
    s.details.update(metrics=r["metrics"],full_io=full["io"],selective_io=r["io"],plan=r["plan"])

@case("PERF-04")
def perf_governed(s):
    if s.lane=="df54":raise Outcome("BLOCKED","governed pruning cannot be measured without a compatible DF54 Policast boundary")
    cat=perf_data(s);raw=s.query(cat,"SELECT * FROM events WHERE id=129");governed=s.governed(cat,"SELECT * FROM events WHERE id=129")
    equal(raw["rows"],records([129]))
    expected=records([129]);expected[0]["secret"]="***";equal(governed["rows"],expected)
    equal(s.governed(cat,"SELECT * FROM events WHERE secret='secret-129'")["rows"],[])
    s.details.update(raw=raw,governed=governed)
    raise Outcome("METRIC","same production ReadBoundary, raw-vs-governed object IO; no security predicate pushdown weakened")

@case("PERF-05")
def perf_planning(s):
    cat=s.init();s.write(cat,records([0]));measured=[]
    for i in range(1,1000):
        s.write(cat,records([i]),"append")
        if i+1 in (10,100,1000):
            assert len(s.live_files(cat))==i+1
            r=s.query(cat,"SELECT * FROM events WHERE id=0",plan_only=True)
            measured.append({"files":i+1,**r})
    equal(s.query(cat,"SELECT id FROM events ORDER BY id")["rows"],[{"id":i} for i in range(1000)])
    s.details["planning"]=measured
    raise Outcome("METRIC","planning evidence from 10/100/1000 real committed files; no wall-clock pass threshold")

@case("PERF-06")
def perf_warm(s):
    cat=perf_data(s,10);w=s.worker();samples=[]
    for i in range(16):
        r=s.query(cat,"SELECT * FROM events WHERE id=129",worker=w);equal(r["rows"],records([129]))
        samples.append({"ms":r["planning_ms"]+r["execution_ms"],"io":r["io"]})
    warm=[x["ms"] for x in samples[1:]]
    s.details.update(first_fresh_process=samples[0],warm_median_ms=statistics.median(warm),warm_p95_ms=sorted(warm)[math.ceil(0.95*len(warm))-1],percentile_method="nearest-rank",samples=samples,cache_scope="fresh process first read, NOT OS or MinIO cache eviction")
    raise Outcome("METRIC","fresh-process and repeated-query latency, exact rowsets checked for every sample")
