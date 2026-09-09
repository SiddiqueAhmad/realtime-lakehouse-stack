#!/usr/bin/env python3
"""Focused integration checks beyond the unchanged qualification cases."""
from run import *

def main():
    if not __debug__:raise RuntimeError('assertions required')
    suite=StandardSuite('df54',HERE/'guard-evidence');report=[]
    try:
        suite.current_case='GUARD-01';cat=suite.init();suite.write(cat,records([1]));head=suite.state(cat)['head']
        for invalid in (-1,head+10000):
            try:suite.query(cat,snapshot=invalid)
            except OperationError as e:assert 'snapshot' in str(e).lower(),str(e)
            else:raise AssertionError('invalid snapshot returned a successful answer')
        report.append('GUARD-01 invalid snapshots rejected')
        suite.current_case='GUARD-02';cat=suite.init();suite.write(cat,records([0]));old=suite.columns(cat)
        fs=FIELDS+[{'name':'region','type':'string','nullable':True}]
        new=[{**records([2])[0],'region':'east'}];suite.write(cat,new,fields=fs)
        before=suite.state(cat)
        try:suite.write(cat,records([1]),'append')
        except OperationError as e:assert 'conflict' in str(e).lower(),str(e)
        else:raise AssertionError('sequential old-schema append retired a live column')
        assert suite.state(cat)['head']==before['head'];suite.exact(cat,new)
        suite.write(cat,[{**records([1])[0],'region':None}],'append',fields=fs)
        actual=suite.rows(cat)
        for row in actual:row.setdefault('region',None)
        equal(actual,new+[{**records([1])[0],'region':None}])
        assert all(suite.columns(cat)[k]==v for k,v in old.items())
        report.append('GUARD-02 omitted live column rejected; retry preserves schema, values and field IDs')
        suite.current_case='GUARD-03';cat=suite.init();result=suite.write(cat,[])
        equal(suite.query(cat,snapshot=result['snapshot'])['rows'],[])
        report.append('GUARD-03 valid empty snapshot remains a valid empty answer')
        suite.current_case='GUARD-04';cat=suite.init();suite.write(cat,records([1]))
        maps=suite.pg_schema(cat,"SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name LIKE 'ducklake_catalog%';")
        assert maps.strip().endswith('0'),maps
        cols=suite.pg_schema(cat,"SELECT count(*) FROM information_schema.columns WHERE table_schema=current_schema() AND column_name='catalog_id';")
        assert cols.strip().endswith('0'),cols
        report.append('GUARD-04 real metadata has no library-specific catalog maps or catalog_id columns')
    finally:
        (suite.output/'guards.json').write_text(json.dumps({'passed':report},indent=2));suite.close()
    for row in report:print('PASS '+row)
if __name__=='__main__':main()
