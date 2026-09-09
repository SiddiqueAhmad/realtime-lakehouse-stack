#!/usr/bin/env python3
"""Standard PostgreSQL lane: reuse behavioral assertions, not old passing labels."""
import sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
BASE=HERE.parent/'delta-policast-sme-demo'
sys.path.insert(0,str(BASE/'tests'))
import test_ducklake_qualification as original
from qualification import harness as h, schema, performance
from qualification.harness import *
import governance_parity
import io

h.COMPOSE=['docker','compose','-f',str(HERE/'docker-compose.yml')]
# APIs actually absent from the standard writer; exact OperationError text is
# required. Missing files, SQL failures, timeouts and wrong rows remain FAILED.
UNSUPPORTED_CASES={'CDC-02','CDC-03','SCHEMA-05','MAINT-02','MAINT-03','MAINT-04','MAINT-05','MAINT-06','MAINT-07','DF54-03','DF54-04'}

class StandardSuite(h.Suite):
    @property
    def image(self):return os.environ.get('STANDARD_IMAGE','ducklake-standard:patched')
    @image.setter
    def image(self,value):pass  # The image is explicitly selected, not the old df54 tag.
    def call(self, op, cat, worker=None, **kw):
        mutations={'dml','promote','compact','cleanup','orphans','native_expire'}
        before=None
        if op in mutations:
            before=(self.state(cat), self.query(cat)['rows'])
        try:
            return super().call(op,cat,worker,**kw)
        except OperationError as error:
            if before is not None and unsupported(error):
                after=(self.state(cat), self.query(cat)['rows'])
                assert before[0]==after[0], 'unsupported operation changed catalog metadata'
                equal(before[1],after[1], 'unsupported operation changed business rows')
            raise
    def pg_schema(self,cat,query):
        if not cat.replace('_','').isalnum():raise ValueError('invalid catalog')
        return self.pg(f'SET search_path TO "lake_{cat}";\n'+query)


def live_governance(fn):
    def run(s):
        old=s.lane;s.lane='standard-df54'
        try:return fn(s)
        finally:s.lane=old
    return run

h.CASES['SCHEMA-07']=live_governance(schema.schema_governance)
h.CASES['PERF-04']=live_governance(performance.perf_governed)

def policy_same_stack(s):
    cat=s.init();s.write(cat,records([1])+records([2],tenant='other'))
    rows=s.governed(cat)['rows'];expected=records([1]);expected[0]['secret']='***';equal(rows,expected)
    names={p['name'] for p in s.graph['packages']}
    assert 'policast-datafusion' in names and 'policast-core' in names
    s.details['proof']='real Policast compiler + GovernedTable + ReadBoundary on the DF54 standard provider'
h.CASES['DF54-05']=policy_same_stack

def deps(s):
    packages=s.graph['packages']
    family={p['name']:p['version'] for p in packages if p['name']=='datafusion' or p['name'].startswith('datafusion-') and p['name']!='datafusion-ducklake'}
    assert set(family.values())=={'54.1.0'},family
    arrow={p['version'] for p in packages if p['name'] in ('arrow','arrow-array','arrow-schema','arrow-buffer')};assert len(arrow)==1,arrow
    assert not any(p['name'] in ('duckdb','libduckdb-sys') for p in packages)
    assert sum(p['name']=='policast-datafusion' for p in packages)==1
    s.details.update(datafusion_family=family,arrow_versions=sorted(arrow))
h.CASES['DF54-06']=deps

def parity(s):
    log=io.StringIO()
    try:
        with contextlib.redirect_stdout(log):governance_parity.run()
    finally:
        (s.output/'governance-20.log').write_text(log.getvalue())
        print(log.getvalue(),flush=True)
    lines=[line for line in log.getvalue().splitlines() if line.startswith('PASS ') and ': ' in line]
    assert len(lines)==20,f'expected original 20 passes, got {len(lines)}'
    s.details.update(original_suite_sha256=hashlib.sha256((BASE/'tests/test_governance.py').read_bytes()).hexdigest(),original_cases_passed=20,image=s.image)
h.CASES['DF54-07']=parity

# The expiry fixture qualifies the snapshot validation fix, not a native
# standard maintenance implementation. MAINT-01 is intentionally NOT a pass.
def native_expiry_absent(s):
    cat=s.init();s.write(cat,records([1]));s.exact(cat,records([1]))
    try:s.call('native_expire',cat)
    except OperationError as e:
        if not unsupported(e):raise
        limited('Native standard expiry is unavailable; TT-05 uses a logical-expiry fixture, not native maintenance')
    raise AssertionError('unqualified native expiry became available')
h.CASES['MAINT-01']=native_expiry_absent


def run_lane(output,selected,expect_red=False):
    manifest=json.loads((BASE/'tests/ducklake_qualification_cases.json').read_text())
    if set(h.CASES)!={c['id'] for c in manifest['cases']}:raise RuntimeError('case coverage drift')
    suite=StandardSuite('df54',output);results=[]
    try:
        for item in manifest['cases']:
            cid=item['id']
            if selected and not any(fnmatch.fnmatchcase(cid,p) for p in selected):continue
            suite.current_case=cid;suite.details={};start=time.monotonic();status='PASS';detail='behavioral assertions satisfied'
            print(f'RUN standard-pg {cid} {item["title"]}',flush=True)
            try:
                if suite.main is None:suite.main=suite.worker()
                h.CASES[cid](suite)
            except Outcome as e:status,detail=e.status,e.detail
            except OperationError as e:
                status='FAILED';detail=str(e)
                if cid in UNSUPPORTED_CASES and unsupported(e):
                    # Confirm the explicitly unsupported mutation did not damage
                    # the committed catalog. All current files must still read.
                    cat=cid.lower().replace('-','_')
                    q=suite.query(cat);fresh=suite.worker()
                    equal(q['rows'],suite.query(cat,worker=fresh)['rows'])
                    status='KNOWN-LIMITATION';detail=f'standard-writer API unavailable: {e}'
            except Exception as e:status='FAILED';detail=str(e);suite.details['traceback']=traceback.format_exc()
            finally:
                if cid=='TT-05':suite.details['expiration']='controlled logical expiry fixture; native expiry/GC NOT qualified'
                try:original.close_case_workers(suite)
                except Exception as e:status='FAILED';detail+=f'; cleanup: {e}'
            result=dict(id=cid,title=item['title'],status=status,detail=detail,seconds=time.monotonic()-start,evidence=suite.details)
            results.append(result);(suite.output/f'{cid}.json').write_text(json.dumps(result,indent=2))
            print(f'{status} standard-pg {cid}: {detail}',flush=True)
        assert results,'no cases selected'
        counts={k:sum(r['status']==k for r in results) for k in ('PASS','FAILED','KNOWN-LIMITATION','METRIC','BLOCKED','NOT_APPLICABLE')}
        report=dict(profile='standard-postgres-df54',image=suite.image,counts=counts,cases=results,full_selection=len(results)==54,scope='standard single-catalog layout isolated with PostgreSQL search_path; simulated CDC; logical-expiry fixture; no cross-engine write-compatibility claim')
        (suite.output/'results.json').write_text(json.dumps(report,indent=2))
        print(f'SUMMARY standard-pg: {counts}',flush=True)
        failures={r['id'] for r in results if r['status']=='FAILED'}
        if expect_red:
            assert {r['id'] for r in results}=={'TT-05','SCHEMA-08'},'red control must run exactly both regression cases'
            assert failures=={'TT-05','SCHEMA-08'},f'unpatched control did not reproduce both: {failures}'
            return False
        return bool(counts['FAILED'] or counts['BLOCKED'])
    finally:suite.close()

if __name__=='__main__':
    if not __debug__:raise RuntimeError('assertions required')
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=HERE/'evidence');p.add_argument('--case',action='append');p.add_argument('--expect-red',action='store_true')
    a=p.parse_args();raise SystemExit(1 if run_lane(a.output,a.case,a.expect_red) else 0)
