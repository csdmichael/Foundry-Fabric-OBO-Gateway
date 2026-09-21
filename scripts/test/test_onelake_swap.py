import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


module_path = Path(__file__).resolve().parents[1] / 'tokenomics' / 'upload-staging-to-onelake.py'
spec = importlib.util.spec_from_file_location('upload_staging_to_onelake', module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeOneLakeClient:
    def __init__(self, fail_destination=None):
        self.paths = {'Tables/ml/one', 'Tables/ml/two'}
        self.actions = []
        self.fail_destination = fail_destination
        self.failed = False

    def exists(self, path):
        return path in self.paths

    def file_exists(self, path):
        self.actions.append(('verify', path))
        return True

    def delete(self, path):
        self.actions.append(('delete', path))
        self.paths.discard(path)

    def rename(self, source, destination):
        self.actions.append(('rename', source, destination))
        if destination == self.fail_destination and not self.failed:
            self.failed = True
            raise RuntimeError('injected swap failure')
        self.paths.discard(source)
        self.paths.add(destination)

    def upload(self, source, destination):
        self.actions.append(('upload', destination))
        stage_path = '/'.join(destination.split('/')[:3])
        self.paths.add(stage_path)


def create_staging(root):
    for table in ('one', 'two'):
        table_root = root / 'ml' / table
        (table_root / '_delta_log').mkdir(parents=True)
        (table_root / '_delta_log' / '000.json').write_text('{}', encoding='utf-8')
        (table_root / 'part.parquet').write_bytes(b'data')


class OneLakeSwapTests(unittest.TestCase):
    def test_uploads_and_verifies_every_file_before_live_swap(self):
        with tempfile.TemporaryDirectory() as directory:
            staging = Path(directory)
            create_staging(staging)
            client = FakeOneLakeClient()
            transaction_path = staging / 'transaction.json'

            result = module.synchronize_tables(client, staging, 'snapshot', transaction_path, max_workers=1)

            first_live_rename = next(
                index for index, action in enumerate(client.actions)
                if action[0] == 'rename' and action[1] in {'Tables/ml/one', 'Tables/ml/two'}
            )
            self.assertTrue(all(action[0] in {'upload', 'verify'} for action in client.actions[:first_live_rename]))
            self.assertEqual(result, {'tableCount': 2, 'fileCount': 4})
            self.assertTrue(transaction_path.is_file())
            self.assertEqual(json.loads(transaction_path.read_text(encoding='utf-8'))['phase'], 'pending_acceptance')
            self.assertIn('Tables/ml/__backup_one_snapshot', client.paths)
            self.assertIn('Tables/ml/__backup_two_snapshot', client.paths)

            module.finalize_transaction(client, json.loads(transaction_path.read_text(encoding='utf-8')))
            transaction_path.unlink()

            self.assertEqual(client.paths, {'Tables/ml/one', 'Tables/ml/two'})

    def test_restores_all_live_tables_after_acceptance_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            staging = Path(directory)
            create_staging(staging)
            client = FakeOneLakeClient()
            transaction_path = staging / 'transaction.json'

            module.synchronize_tables(client, staging, 'snapshot', transaction_path, max_workers=1)
            module.rollback_transaction(client, json.loads(transaction_path.read_text(encoding='utf-8')))
            module.rollback_transaction(client, json.loads(transaction_path.read_text(encoding='utf-8')))
            transaction_path.unlink()

            self.assertEqual(client.paths, {'Tables/ml/one', 'Tables/ml/two'})
            self.assertFalse(any('__backup_' in path or '__stage_' in path for path in client.paths))

    def test_rejects_transaction_for_another_fabric_target(self):
        transaction = {
            'workspaceId': 'workspace-a',
            'lakehouseId': 'lakehouse-a',
            'configFingerprint': 'fingerprint-a',
        }
        target = {
            'workspaceId': 'workspace-b',
            'lakehouseId': 'lakehouse-a',
            'configFingerprint': 'fingerprint-a',
        }

        with self.assertRaisesRegex(RuntimeError, 'workspaceId'):
            module.validate_transaction_target(transaction, target)

    def test_rollback_preserves_original_when_interrupted_before_first_rename(self):
        client = FakeOneLakeClient()
        transaction = {
            'tables': [{
                'finalPath': 'Tables/ml/one',
                'stagePath': 'Tables/ml/__stage_one_snapshot',
                'backupPath': 'Tables/ml/__backup_one_snapshot',
                'hadOriginal': True,
                'swapped': True,
            }],
        }

        module.rollback_transaction(client, transaction)

        self.assertIn('Tables/ml/one', client.paths)
        self.assertNotIn(('delete', 'Tables/ml/one'), client.actions)

    def test_partial_finalization_is_resumed_not_rolled_back(self):
        client = FakeOneLakeClient()
        client.paths = {'Tables/ml/one', 'Tables/ml/two', 'Tables/ml/__backup_two_snapshot'}
        transaction = {
            'phase': 'finalizing',
            'tables': [
                {'finalPath': 'Tables/ml/one', 'stagePath': 'Tables/ml/__stage_one_snapshot', 'backupPath': 'Tables/ml/__backup_one_snapshot', 'hadOriginal': True, 'swapped': True},
                {'finalPath': 'Tables/ml/two', 'stagePath': 'Tables/ml/__stage_two_snapshot', 'backupPath': 'Tables/ml/__backup_two_snapshot', 'hadOriginal': True, 'swapped': True},
            ],
        }

        module.finalize_transaction(client, transaction)

        self.assertEqual(client.paths, {'Tables/ml/one', 'Tables/ml/two'})

    def test_restores_all_live_tables_when_a_swap_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            staging = Path(directory)
            create_staging(staging)
            client = FakeOneLakeClient(fail_destination='Tables/ml/two')

            with self.assertRaisesRegex(RuntimeError, 'OneLake table swap failed'):
                module.synchronize_tables(client, staging, 'snapshot', max_workers=1)

            self.assertIn('Tables/ml/one', client.paths)
            self.assertIn('Tables/ml/two', client.paths)
            self.assertFalse(any('__backup_' in path for path in client.paths))


if __name__ == '__main__':
    unittest.main()