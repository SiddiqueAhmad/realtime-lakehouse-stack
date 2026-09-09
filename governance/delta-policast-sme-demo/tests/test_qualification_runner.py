"""Guards for the executable harness, not a replacement for integration tests."""
import importlib.util
import json
from pathlib import Path
import unittest

PATH = Path(__file__).with_name('test_ducklake_qualification.py')
spec = importlib.util.spec_from_file_location('qualification_runner', PATH)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ExecutableRunnerTests(unittest.TestCase):
    def test_every_contract_case_has_an_executable_function(self):
        manifest = json.loads(PATH.with_name('ducklake_qualification_cases.json').read_text())
        self.assertEqual(set(runner.CASES), {c['id'] for c in manifest['cases']})
        self.assertEqual(len(runner.CASES), 54)
        self.assertTrue(all(callable(f) for f in runner.CASES.values()))

    def test_rowset_assertion_preserves_duplicates(self):
        with self.assertRaises(AssertionError):
            runner.equal([{'id': 1}, {'id': 1}], [{'id': 1}])

    def test_rowset_assertion_detects_wrong_values(self):
        with self.assertRaises(AssertionError):
            runner.equal([{'id': 1, 'value': 2}], [{'id': 1, 'value': 3}])

    def test_infrastructure_failure_is_not_a_known_limitation(self):
        for message in ('connection refused', 'worker panicked', 'object not found', 'timeout', 'rowset mismatch'):
            self.assertFalse(runner.unsupported(runner.OperationError(message)), message)

    def test_replay_tombstone_and_sequence_are_persisted(self):
        original = runner.change(1, 102, 5, True)
        class Storage:
            writes = 0
            def rows(self, cat, worker): return [dict(original)]
            def write(self, *a, **kw): self.writes += 1
        storage = Storage()
        result = runner.materialize(storage, 'test', [runner.change(1, 101, 4), dict(original)])
        self.assertEqual(result, [original])
        self.assertEqual(storage.writes, 0)

    def test_conflicting_same_sequence_is_rejected(self):
        class Storage:
            def rows(self, cat, worker): return [runner.change(1, 2, 1)]
        with self.assertRaises(AssertionError):
            runner.materialize(Storage(), 'test', [runner.change(1, 2, 999)])


if __name__ == '__main__': unittest.main()
