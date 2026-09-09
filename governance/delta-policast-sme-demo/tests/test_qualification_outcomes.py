"""Result classification guards; actual behavior runs in the separate runner."""
import unittest
from test_ducklake_qualification import classify_outcome

class OutcomeTests(unittest.TestCase):
    def test_required_df54_features_cannot_be_downgraded_to_limitation(self):
        for case in ('SCHEMA-05','MAINT-06','MAINT-07','PERF-02','DF54-04'):
            self.assertEqual(classify_outcome('df54',case,'KNOWN-LIMITATION','unsupported')[0],'FAILED')

    def test_df53_unsupported_feature_remains_explicit_not_pass(self):
        self.assertEqual(classify_outcome('df53','MAINT-06','KNOWN-LIMITATION','no API')[0],'KNOWN-LIMITATION')

    def test_wrong_results_never_become_limitations(self):
        for lane in ('df53','df54'):
            self.assertEqual(classify_outcome(lane,'PERF-02','FAILED','wrong rows')[0],'FAILED')

    def test_blocked_governance_does_not_become_pass(self):
        self.assertEqual(classify_outcome('df54','DF54-07','BLOCKED','no compatible Policast')[0],'BLOCKED')
