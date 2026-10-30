import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fork_logging', ROOT / 'scripts/fork/check-logging-entrypoints.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ForkLoggingTests(unittest.TestCase):
    def test_retired_upstream_workflow_is_not_restored_for_backend_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archived = root / '.github/disabled-workflows'
            archived.mkdir(parents=True)
            (archived / 'current.yml').write_text('current')
            (archived / 'retired.yml').write_text('retired')
            guard.restore_archived_workflows(root, upstream_files={'.github/workflows/current.yml'})
            self.assertEqual((root / '.github/workflows/current.yml').read_text(), 'current')
            self.assertFalse((root / '.github/workflows/retired.yml').exists())

    def test_archived_workflow_does_not_replace_an_active_definition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            active = root / '.github/workflows'
            archived = root / '.github/disabled-workflows'
            active.mkdir(parents=True)
            archived.mkdir()
            (active / 'existing.yml').write_text('active')
            (archived / 'existing.yml').write_text('archived')
            (archived / 'missing.yml').write_text('restored')
            guard.restore_archived_workflows(root)
            self.assertEqual((active / 'existing.yml').read_text(), 'active')
            self.assertEqual((active / 'missing.yml').read_text(), 'restored')

    def test_upstream_guard_still_rejects_logging_and_missing_workflow(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            guard.stage_current(ROOT, root)
            command = [sys.executable, str(root / 'backend/scripts/check_logging_entrypoints.py')]
            clean = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
            main = root / 'backend/main.py'
            original = main.read_text()
            main.write_text(original + '\nprint("synthetic logging regression")\n')
            regression = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertNotEqual(regression.returncode, 0)
            self.assertIn('exceeds pending', regression.stdout)
            main.write_text(original)
            (root / '.github/workflows/gcp_backend_auto_dev.yml').unlink()
            missing = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('declared deployment workflow does not exist', missing.stdout)


if __name__ == '__main__':
    unittest.main()
