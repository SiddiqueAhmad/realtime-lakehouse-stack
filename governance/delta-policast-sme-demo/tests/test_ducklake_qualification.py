#!/usr/bin/env python3
"""Run real DuckLake qualification against Postgres/MinIO (not manifest checks)."""
from qualification.harness import *
from qualification import cdc, concurrency, snapshots, schema, maintenance, performance, df54
from qualification.cdc import change, materialize


def run_lane(lane,output,selected):
    manifest=json.loads((ROOT/"tests/ducklake_qualification_cases.json").read_text())
    expected={c["id"] for c in manifest["cases"]}
    assert set(CASES)==expected,f"executable cases differ from contract: missing={expected-set(CASES)}, extra={set(CASES)-expected}"
    suite=Suite(lane,output);results=[]
    try:
        for item in manifest["cases"]:
            case_id=item["id"]
            if selected and not any(fnmatch.fnmatchcase(case_id,p) for p in selected):continue
            suite.current_case=case_id;suite.details={};start=time.monotonic()
            status="PASS";detail="all behavioral assertions satisfied"
            try:CASES[case_id](suite)
            except Outcome as outcome:status,detail=outcome.status,outcome.detail
            except Exception as error:
                status="FAILED";detail=str(error);suite.details["traceback"]=traceback.format_exc()
                with contextlib.suppress(Exception):suite.details["catalog_state_on_failure"]=suite.state(case_id.lower().replace('-','_'))
            finally:suite.cleanup_workers()
            result={"id":case_id,"title":item["title"],"lane":lane,"status":status,"detail":detail,"seconds":time.monotonic()-start,"evidence":suite.details}
            results.append(result)
            (suite.output/f"{case_id}.json").write_text(json.dumps(result,indent=2))
            print(f"{status} {lane} {case_id} {item['title']}: {detail}",flush=True)
        assert results, "No executable cases selected"
        counts={st:sum(r["status"]==st for r in results) for st in ("PASS","FAILED","KNOWN-LIMITATION","METRIC","BLOCKED","NOT_APPLICABLE")}
        report={"lane":lane,"run_id":suite.run_id,"database":suite.database,"data_path":suite.root,"counts":counts,"cases":results,"qualification_complete":not counts["FAILED"] and not counts["BLOCKED"],"scope":"library-specific Postgres multicatalog + MinIO; simulated CDC, no WAL/connector; functional build, not optimized performance"}
        (suite.output/"results.json").write_text(json.dumps(report,indent=2))
        print(f"SUMMARY {lane}: {json.dumps(counts)}",flush=True)
        return counts["FAILED"]>0
    finally:suite.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane",choices=["df53","df54","all"],default="all")
    parser.add_argument("--output",type=Path,default=ROOT/"qualification-evidence")
    parser.add_argument("--case",action="append",help="glob such as CONC-*; omitted runs every case")
    args=parser.parse_args();failed=False
    for lane in (["df53","df54"] if args.lane=="all" else [args.lane]):
        try:failed=run_lane(lane,args.output,args.case) or failed
        except Exception:
            traceback.print_exc();failed=True
    raise SystemExit(1 if failed else 0)


if __name__=="__main__":main()
