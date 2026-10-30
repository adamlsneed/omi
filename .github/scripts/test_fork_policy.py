import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('fork_policy', Path(__file__).with_name('fork_policy.py'))


class ForkPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('remote', 'add', 'origin', 'https://github.com/adamlsneed/omi.git')
        self.path = self.root / 'backend/example.py'
        self.path.parent.mkdir()
        self.path.write_text('original\n')
        exception = self.root / 'backend/tests/unit/test_edit_tools_resilience.py'
        exception.parent.mkdir(parents=True)
        exception.write_text('upstream test\n')
        (exception.parent / 'test_task_integrations_sanitization.py').write_text('upstream test\n')
        (exception.parent / 'test_episode_boundary_evidence.py').write_text('upstream test\n')
        inventory = self.root / 'backend/config/task_intelligence_sources_v1.json'
        inventory.parent.mkdir()
        inventory.write_text('upstream inventory\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'baseline')
        self.git('update-ref', 'refs/remotes/upstream/main', 'HEAD')
        self.policy = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(self.policy)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def test_mirror_requires_exact_current_bytes(self):
        self.assertTrue(self.policy.mirrors_upstream(self.root, 'backend/example.py'))
        self.path.write_text('changed\n')
        self.assertFalse(self.policy.mirrors_upstream(self.root, 'backend/example.py'))

    def test_nonfork_does_not_receive_an_exemption(self):
        self.git('remote', 'set-url', 'origin', 'https://github.com/example/omi.git')
        self.assertFalse(self.policy.mirrors_upstream(self.root, 'backend/example.py'))

    def test_checkout_remote_without_git_suffix_is_recognized(self):
        self.git('remote', 'set-url', 'origin', 'https://github.com/adamlsneed/omi')
        self.assertTrue(self.policy.mirrors_upstream(self.root, 'backend/example.py'))

    def test_missing_upstream_ref_fails_closed(self):
        self.git('update-ref', '-d', 'refs/remotes/upstream/main')
        with self.assertRaises(subprocess.CalledProcessError):
            self.policy.mirrors_upstream(self.root, 'backend/example.py')

    def test_backend_guard_rejects_changes_in_worktree_and_index(self):
        self.policy.verify_backend(self.root)
        self.path.write_text('changed\n')
        with self.assertRaises(ValueError):
            self.policy.verify_backend(self.root)
        self.git('add', '.')
        with self.assertRaises(ValueError):
            self.policy.verify_backend(self.root, cached=True)

    def test_sync_merge_verifies_the_incoming_upstream_revision(self):
        self.git('checkout', '-qb', 'incoming')
        self.path.write_text('new upstream bytes\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'upstream update')
        self.git('update-ref', 'refs/remotes/upstream/main', 'HEAD')
        self.git('checkout', '-q', '-')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com',
                 'merge', '--no-commit', '--no-ff', 'incoming')
        self.policy.verify_backend(self.root, cached=True)


if __name__ == '__main__':
    unittest.main()
