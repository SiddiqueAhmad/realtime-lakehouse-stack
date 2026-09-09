import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests" / "ducklake_qualification_cases.json"


class DuckLakeQualificationManifestTest(unittest.TestCase):
    def setUp(self):
        self.doc = json.loads(MANIFEST.read_text())
        self.cases = self.doc["cases"]

    def test_required_areas_exist(self):
        areas = {case["area"] for case in self.cases}
        self.assertEqual(
            areas,
            {
                "cdc",
                "concurrency",
                "multiwriter",
                "time-travel",
                "schema-evolution",
                "maintenance",
                "partition-perf",
                "df54",
            },
        )

    def test_ids_are_unique_and_named(self):
        ids = [case["id"] for case in self.cases]
        self.assertEqual(len(ids), len(set(ids)), "qualification case ids must be unique")
        expected_prefixes = {"CDC", "CONC", "MW", "TT", "SCHEMA", "MAINT", "PERF", "DF54"}
        self.assertEqual({case_id.split("-")[0] for case_id in ids}, expected_prefixes)

    def test_every_case_declares_lane_expectations(self):
        for case in self.cases:
            with self.subTest(case=case["id"]):
                self.assertTrue(case.get("title"))
                self.assertTrue(case.get("mode"))
                self.assertIn("df53", case)
                self.assertIn("df54", case)
                self.assertNotEqual(case["df53"], "")
                self.assertNotEqual(case["df54"], "")

    def test_no_case_calls_characterization_a_pass(self):
        # A known limitation must remain explicit in the manifest. This guards
        # against future edits that simply rename a limitation into a passing
        # assertion without adding an executable qualification case.
        for case in self.cases:
            with self.subTest(case=case["id"]):
                if case["mode"] == "characterization":
                    self.assertTrue(
                        any(token in case["df53"] for token in ("characterize", "failure", "limitation"))
                        or any(token in case["df54"] for token in ("characterize", "failure", "limitation"))
                    )

    def test_governed_df54_is_not_claimed_today(self):
        case = next(case for case in self.cases if case["id"] == "DF54-05")
        self.assertIn("known-limitation", case["df54"])
        self.assertIn("policast", case["df54"])

    def test_suite_has_depth(self):
        counts = {}
        for case in self.cases:
            counts[case["area"]] = counts.get(case["area"], 0) + 1
        for area in ["cdc", "concurrency", "multiwriter", "time-travel", "schema-evolution", "maintenance", "partition-perf", "df54"]:
            with self.subTest(area=area):
                self.assertGreaterEqual(counts[area], 6)


if __name__ == "__main__":
    unittest.main()
