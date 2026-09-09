import types
import unittest
import run

class RunnerChecks(unittest.TestCase):
    def good_packages(self):
        return [
            {'name':'datafusion','version':'54.1.0'},
            {'name':'datafusion-catalog','version':'54.1.0'},
            {'name':'datafusion-ducklake','version':'0.7.0'},
            {'name':'arrow','version':'58.4.0'},
            {'name':'arrow-array','version':'58.4.0'},
            {'name':'arrow-schema','version':'58.4.0'},
            {'name':'policast-datafusion','version':'0.1.0'},
            {'name':'policast-core','version':'0.1.0'},
        ]
    def check_graph(self, packages):
        obj=types.SimpleNamespace(graph={'packages':packages},details={})
        run.deps(obj)
    def test_coherent_graph_passes(self):self.check_graph(self.good_packages())
    def test_duplicate_df_version_not_hidden_by_dictionary(self):
        packages=[{'name':'datafusion','version':'53.1.0'}]+self.good_packages()
        with self.assertRaises(AssertionError):self.check_graph(packages)
    def test_same_version_duplicate_source_rejected(self):
        packages=self.good_packages()+[{'name':'datafusion','version':'54.1.0'}]
        with self.assertRaises(AssertionError):self.check_graph(packages)
    def test_duckdb_runtime_not_accidentally_bundled(self):
        with self.assertRaises(AssertionError):self.check_graph(self.good_packages()+[{'name':'libduckdb-sys','version':'1.4.1'}])
    def test_all_cases_remain_accounted_for(self):
        manifest=run.json.loads((run.BASE/'tests/ducklake_qualification_cases.json').read_text())
        self.assertEqual(set(run.h.CASES),{c['id'] for c in manifest['cases']})
        self.assertEqual(len(run.h.CASES),54)
    def test_governed_cases_really_replaced_the_blocked_gates(self):
        self.assertIs(run.h.CASES['DF54-05'],run.policy_same_stack)
        self.assertIs(run.h.CASES['DF54-07'],run.parity)
    def test_existing_governance_case_file_is_not_copied(self):
        self.assertTrue((run.BASE/'tests/test_governance.py').exists())
        self.assertFalse((run.HERE/'test_governance.py').exists())

    def test_red_control_requires_the_actual_bug_not_infrastructure(self):
        valid=[{'id':'TT-05','status':'FAILED','detail':'expired snapshot accepted and returned []'},
               {'id':'SCHEMA-08','status':'FAILED','detail':'rowset mismatch: region disappeared'}]
        run.verify_red_control(valid)
        for detail in ['connection refused','container crashed','not a retryable conflict']:
            invalid=[dict(item) for item in valid];invalid[0]['detail']=detail
            with self.assertRaises(AssertionError):run.verify_red_control(invalid)
    def test_red_control_cannot_accept_pass_or_missing_case(self):
        with self.assertRaises(AssertionError):run.verify_red_control([])
        with self.assertRaises(AssertionError):
            run.verify_red_control([{'id':'TT-05','status':'PASS','detail':''},
                                    {'id':'SCHEMA-08','status':'FAILED','detail':'rowset mismatch:'}])

if __name__=='__main__':unittest.main()
