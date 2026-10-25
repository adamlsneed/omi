"""Archived fork deployment contracts retain their concurrency validation."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('deployment_concurrency', ROOT / '.github/scripts/check-deployment-concurrency.py')
GUARD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GUARD
SPEC.loader.exec_module(GUARD)
NAME = 'gcp_backend_listen_helm.yml'


class ArchivedConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('workflows', 'disabled-workflows'):
            shutil.copytree(ROOT / '.github' / name, self.root / name)
        self.active = self.root / 'workflows'
        self.archived = self.root / 'disabled-workflows'

    def errors(self):
        with patch.object(GUARD, 'WORKFLOWS', self.active), patch.object(
            GUARD, 'ARCHIVED_WORKFLOWS', self.archived, create=True
        ):
            return GUARD.check_repository()

    def test_archived_writer_is_validated_without_activation(self):
        self.assertEqual(self.errors(), [])
        self.assertFalse((self.active / NAME).exists())

    def test_archived_writer_losing_its_lock_fails(self):
        path = self.archived / NAME
        path.write_text(path.read_text().replace('concurrency:', 'former-concurrency:', 1))
        self.assertTrue(any(NAME in error and 'concurrency' in error for error in self.errors()))

    def test_missing_audited_writer_still_fails(self):
        (self.archived / NAME).unlink()
        self.assertTrue(any(NAME in error and 'no concurrency group' in error for error in self.errors()))

    def test_active_writer_cannot_hide_behind_valid_archive(self):
        text = (self.archived / NAME).read_text().replace('concurrency:', 'former-concurrency:', 1)
        (self.active / NAME).write_text(text)
        self.assertTrue(any(NAME in error and 'concurrency' in error for error in self.errors()))


if __name__ == '__main__':
    unittest.main()
