#!/usr/bin/env python3
"""Run real DuckLake qualification against Postgres/MinIO (not manifest checks)."""
from qualification.harness import *
from qualification import cdc, concurrency, snapshots, schema, maintenance, performance, df54
from qualification.cdc import change, materialize


def close_case_workers(suite):
    """Do not let a crashed main worker poison the following test cases."""
    errors = []
    for worker in suite.workers:
        try:
            worker.close()
        except Exception as error:
            errors.append(str(error))
    suite.workers = []
    suite.main = None
    if errors:
        raise RuntimeError(f"worker cleanup failed: {errors}")


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
            print(f"RUN {lane} {case_id} {item['title']}",flush=True)
            status="PASS";detail="all behavioral assertions satisfied"
            try:
                if suite.main is None:
                    suite.main=suite.worker()
                CASES[case_id](suite)
            except Outcome as outcome:status,detail=outcome.status,outcome.detail
            except Exception as error:
                status="FAILED";detail=str(error);suite.details["traceback"]=traceback.format_exc()
                with contextlib.suppress(Exception):suite.details["catalog_state_on_failure"]=suite.state(case_id.lower().replace('-','_'))
            finally:
                try:
                    close_case_workers(suite)
                except Exception as error:
                    status="FAILED"
                    detail=f"{detail}; cleanup: {error}"
            result={"id":case_id,"title":item["title"],"lane":lane,"status":status,"detail":detail,"seconds":time.monotonic()-start,"evidence":suite.details}
            results.append(result)
            (suite.output/f"{case_id}.json").write_text(json.dumps(result,indent=2))
            print(f"{status} {lane} {case_id} {item['title']}: {detail}",flush=True)
        assert results, "No executable cases selected"
        counts={st:sum(r["status"]==st for r in results) for st in ("PASS","FAILED","KNOWN-LIMITATION","METRIC","BLOCKED","NOT_APPLICABLE")}
        full_selection=len(results)==len(manifest["cases"])
        report={"lane":lane,"run_id":suite.run_id,"database":suite.database,"data_path":suite.root,"counts":counts,"cases":results,"full_selection":full_selection,"qualification_complete":full_selection and not counts["FAILED"] and not counts["BLOCKED"],"scope":"library-specific Postgres multicatalog + MinIO; simulated CDC, no WAL/connector; functional build, not optimized performance"}
        (suite.output/"results.json").write_text(json.dumps(report,indent=2))
        print(f"SUMMARY {lane}: {json.dumps(counts)}",flush=True)
        return counts["FAILED"]>0
    finally:suite.close()


def main():
    if not __debug__:
        raise RuntimeError("Qualification requires assertions; unset PYTHONOPTIMIZE and do not use python -O")
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
