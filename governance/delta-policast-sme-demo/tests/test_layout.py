"""Static architecture checks; no Docker or cloud access needed."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class LayoutTests(unittest.TestCase):
    def test_runtime_is_domain_neutral(self):
        for path in (ROOT / 'app/src').rglob('*.rs'):
            production = path.read_text().split('#[cfg(test)]', 1)[0].lower()
            for word in ('patients', 'patient_id', 'diagnosis', 'physician', 'ssn'):
                self.assertNotIn(word, production, f'{path}: fixture leaked into runtime')

    def test_query_path_does_not_seed(self):
        main = (ROOT / 'app/src/main.rs').read_text()
        for forbidden in ('ensure_demo_delta', 'WriteBuilder', 'CreateBuilder', 'Field::new', 'TABLE_NAME'):
            self.assertNotIn(forbidden, main)
        self.assertIn('load_table', main)

    def test_fixtures_have_different_schemas(self):
        one = json.loads((ROOT / 'fixtures/healthcare/table.json').read_text())
        two = json.loads((ROOT / 'fixtures/trading/table.json').read_text())
        self.assertNotEqual(one['fields'], two['fields'])
        for fixture in (one, two):
            names = [field['name'] for field in fixture['fields']]
            self.assertEqual(len(names), len(set(names)))
            for row in fixture['rows']:
                self.assertEqual(set(names), set(row))

if __name__ == '__main__':
    unittest.main()
