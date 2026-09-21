import sys
import unittest
from pathlib import Path

import pyarrow as pa

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tokenomics'))

from delta_schema import to_arrow_table


class DeltaSchemaTests(unittest.TestCase):
    def test_empty_provider_uses_governed_reference_types(self):
        reference = [{
            'source_code': 'aws',
            'request_count': 12,
            'total_tokens': 3400,
            'reported_cost_usd': 1.25,
            'is_stream': True,
        }]

        table = to_arrow_table([], reference)

        self.assertEqual(table.num_rows, 0)
        self.assertEqual(table.schema.field('source_code').type, pa.string())
        self.assertEqual(table.schema.field('request_count').type, pa.int64())
        self.assertEqual(table.schema.field('total_tokens').type, pa.int64())
        self.assertEqual(table.schema.field('reported_cost_usd').type, pa.float64())
        self.assertEqual(table.schema.field('is_stream').type, pa.bool_())


if __name__ == '__main__':
    unittest.main()