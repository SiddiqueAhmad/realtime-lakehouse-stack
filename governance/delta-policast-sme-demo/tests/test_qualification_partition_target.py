"""Prevent a wrong schema in the actual partition qualification operation."""
import unittest
from qualification.performance import perf_partition


class StopAfterDdl(Exception):
    pass


class PartitionTargetTests(unittest.TestCase):
    def test_partition_ddl_qualifies_the_real_fixture_schema(self):
        commands = []

        class Capture:
            def init(self):
                return 'test_catalog'

            def write(self, *args, **kwargs):
                pass

            def call(self, op, catalog, **kwargs):
                commands.append((op, catalog, kwargs))
                raise StopAfterDdl()

        with self.assertRaises(StopAfterDdl):
            perf_partition(Capture())
        self.assertEqual(commands, [
            ('dml', 'test_catalog', {'sql': 'ALTER TABLE lake.public.events SET PARTITIONED BY (tenant)'})
        ])


if __name__ == '__main__':
    unittest.main()
