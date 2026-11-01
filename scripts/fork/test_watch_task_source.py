from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

from watch_task_source import add_watch_source, install_manifest_loader, REGISTRATION


class WatchRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'sources': [{
            'id': 'mobile_manual', 'policy_class': 'direct_command',
            'owner_paths': ['app/lib/existing.dart'],
            'writer_anchors': [{'path': 'app/lib/existing.dart', 'symbol': 'client.createTask', 'discover': True}],
            'test_adapter': 'direct_command_contract',
        }, {'id': 'unrelated', 'value': 'retained'}]}

    def test_registration_only_adds_without_mutating_upstream(self):
        original = deepcopy(self.manifest)
        result = add_watch_source(self.manifest)
        self.assertEqual(original, self.manifest)
        self.assertEqual(original['sources'][1], result['sources'][1])
        before, after = original['sources'][0], result['sources'][0]
        for key in ('owner_paths', 'writer_anchors'):
            self.assertEqual(after[key][:len(before[key])], before[key])
        for key in ('id', 'policy_class', 'test_adapter'):
            self.assertEqual(before[key], after[key])
        self.assertEqual(result, add_watch_source(result))

    def test_missing_registration_fails(self):
        with self.assertRaises(FileNotFoundError):
            add_watch_source(self.manifest, Path('/nonexistent/watch-registration.json'))

    def test_malformed_or_non_watch_registration_fails(self):
        valid = json.loads(REGISTRATION.read_text())
        cases = [None, {}, {'owner_paths': [], 'writer_anchors': []}]
        for key, value in [('owner_paths', ['backend/other.py']), ('writer_anchors', [])]:
            changed = deepcopy(valid)
            changed[key] = value
            cases.append(changed)
        for key, value in [('discover', False), ('symbol', 'client.deleteTask'), ('path', 'app/lib/other.dart')]:
            changed = deepcopy(valid)
            changed['writer_anchors'][0][key] = value
            cases.append(changed)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source.json'
            for case in cases:
                with self.subTest(case=case):
                    path.write_text(json.dumps(case))
                    with self.assertRaises(ValueError):
                        add_watch_source(self.manifest, path)
            path.write_text('{bad json')
            with self.assertRaises(ValueError):
                add_watch_source(self.manifest, path)

    def test_missing_or_proposing_mobile_source_fails(self):
        self.manifest['sources'][0]['policy_class'] = 'shared_capture_policy'
        with self.assertRaises(ValueError):
            add_watch_source(self.manifest)
        self.manifest['sources'].pop(0)
        with self.assertRaises(ValueError):
            add_watch_source(self.manifest)

    def test_loader_preserves_explicit_paths_and_returns_fresh_inventory(self):
        calls = []

        def original(*args):
            calls.append(args)
            return deepcopy(self.manifest)

        contracts = SimpleNamespace(load_source_manifest=original)
        self.assertIs(install_manifest_loader(contracts), original)
        self.assertEqual(contracts.load_source_manifest(Path('fixture.json')), self.manifest)
        self.assertEqual(calls, [(Path('fixture.json'),)])
        first = contracts.load_source_manifest()
        first['sources'].clear()
        self.assertTrue(contracts.load_source_manifest()['sources'])

    def test_wrapper_keeps_caller_options_and_activates_plugin_in_children(self):
        folder = Path(__file__).resolve().parent
        env = {**os.environ, 'PYTHONPATH': '/existing/path', 'PYTEST_ADDOPTS': '-q'}
        output = subprocess.check_output([
            'bash', str(folder / 'backend-test-env.sh'), sys.executable, '-c',
            'import json, os; print(json.dumps([os.environ["PYTHONPATH"], os.environ["PYTEST_ADDOPTS"]]))',
        ], env=env, text=True)
        path, options = json.loads(output)
        self.assertEqual(path, str(folder) + os.pathsep + '/existing/path')
        self.assertEqual(options, '-q -p omi_fork_pytest')


if __name__ == '__main__':
    unittest.main()
