import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('fork_module_isolation', Path(__file__).with_name('check-module-isolation.py'))
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)
RUNNERS = ('scripts/pre-push', 'scripts/backend-ratchet-preflight', '.github/workflows/backend-unit-tests.yml')


class ModuleIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / '.gitignore').write_text('__pycache__/\n')
        self.git('init', '-q')
        self.git('remote', 'add', 'origin', 'https://github.com/adamlsneed/omi.git')
        for name in (*RUNNERS, GUARD.TEST, 'backend/scripts/check_module_stub_pollution.py',
                     'backend/tests/.module_stub_legacy_allowlist', 'scripts/fork/omi_fork_pytest.py',
                     'scripts/fork/backend-test-env.sh', 'scripts/fork/test-backend-support.sh'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'baseline')
        self.git('update-ref', 'refs/remotes/upstream/main', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.PIPE).strip()

    def test_original_checker_still_rejects_stub_but_verified_adapter_passes(self):
        checker = self.root / 'backend/scripts/check_module_stub_pollution.py'
        result = subprocess.run([sys.executable, str(checker), '--quiet'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(GUARD.TEST, result.stderr)
        self.assertEqual(GUARD.run(self.root, base='HEAD'), 0)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_changed_backend_bytes_are_rejected(self):
        target = self.root / GUARD.TEST
        target.write_text(target.read_text() + '\n# any unreviewed change\n')
        with self.assertRaisesRegex(ValueError, 'exact reviewed upstream'):
            GUARD.run(self.root)

    def test_new_pollution_is_still_rejected(self):
        target = self.root / 'backend/tests/test_new_pollution.py'
        target.write_text('import sys\nsys.modules["another"] = object()\n')
        self.assertEqual(GUARD.run(self.root, base='HEAD'), 1)

    def test_original_allowlist_cannot_grow(self):
        target = self.root / 'backend/tests/.module_stub_legacy_allowlist'
        target.write_text(target.read_text() + '\nbackend/tests/test_new_pollution.py\n')
        self.assertEqual(GUARD.run(self.root, base='HEAD'), 1)

    def test_missing_real_jinja_import_is_rejected(self):
        target = self.root / 'scripts/fork/omi_fork_pytest.py'
        target.write_text(target.read_text().replace('import jinja2', '# import jinja2', 1))
        with self.assertRaisesRegex(ValueError, 'import real Jinja2 unconditionally'):
            GUARD.run(self.root)

    def test_missing_plugin_activation_is_rejected(self):
        target = self.root / 'scripts/fork/backend-test-env.sh'
        target.write_text(target.read_text().replace('-p omi_fork_pytest', '', 1))
        with self.assertRaisesRegex(ValueError, 'must load omi_fork_pytest'):
            GUARD.run(self.root)

    def test_wrapper_cannot_unset_activation_after_exporting_it(self):
        target = self.root / 'scripts/fork/backend-test-env.sh'
        target.write_text(target.read_text().replace('exec "$@"', 'unset PYTEST_ADDOPTS\nexec "$@"'))
        with self.assertRaisesRegex(ValueError, 'child must receive the registered preload plugin'):
            GUARD.run(self.root)

    def test_wrapper_cannot_unset_plugin_path_after_exporting_it(self):
        target = self.root / 'scripts/fork/backend-test-env.sh'
        target.write_text(target.read_text().replace('exec "$@"', 'unset PYTHONPATH\nexec "$@"'))
        with self.assertRaisesRegex(ValueError, 'child must receive the registered preload plugin'):
            GUARD.run(self.root)

    def test_each_backend_runner_requires_preload(self):
        for name in RUNNERS:
            with self.subTest(name=name):
                target = self.root / name
                original = target.read_text()
                target.write_text(original.replace('bash ../scripts/fork/backend-test-env.sh bash ', 'bash ', 1))
                with self.assertRaisesRegex(ValueError, 'through the fork preload environment'):
                    GUARD.run(self.root)
                target.write_text(original)

    def test_regression_runner_requires_preload(self):
        target = self.root / 'scripts/fork/test-backend-support.sh'
        target.write_text(target.read_text().replace('bash "$fork_test_root/scripts/fork/backend-test-env.sh"', 'bash backend/test.sh'))
        with self.assertRaisesRegex(ValueError, 'regression suite must use the preload'):
            GUARD.run(self.root)

    def test_same_bytes_must_also_match_integrated_upstream(self):
        target = self.root / GUARD.TEST
        original = target.read_bytes()
        target.write_bytes(original + b'\n# upstream drift\n')
        self.git('add', GUARD.TEST)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'upstream changed')
        self.git('update-ref', 'refs/remotes/upstream/main', 'HEAD')
        target.write_bytes(original)
        with self.assertRaisesRegex(ValueError, 'exact reviewed upstream'):
            GUARD.run(self.root)


if __name__ == '__main__':
    unittest.main()
