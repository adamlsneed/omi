#!/usr/bin/env python3
"""The October 25 test-only exception must not admit arbitrary backend changes."""
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TEST_PATH = "backend/tests/unit/test_edit_tools_resilience.py"
UPSTREAM_BLOB = "32acf6628b479ce2c9d6b9b5fac81b265386d8a7"
EXCEPTIONS = runpy.run_path(str(ROOT / '.github/scripts/fork_policy.py'))['BACKEND_EXCEPTIONS']


class BackendMirrorExceptionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/adamlsneed/omi.git")
        self.original = subprocess.check_output(["git", "cat-file", "blob", UPSTREAM_BLOB], cwd=ROOT)
        for path, (upstream_blob, _) in EXCEPTIONS.items():
            self.write(path, subprocess.check_output(['git', 'cat-file', 'blob', upstream_blob], cwd=ROOT))
        self.write("backend/other.py", b"value = 1\n")
        self.write(".github/scripts/check_git_author_identity.py", b"raise SystemExit(0)\n")
        self.write('.github/scripts/fork_policy.py', (ROOT / '.github/scripts/fork_policy.py').read_bytes())
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "base")
        self.git("update-ref", "refs/remotes/upstream/main", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, env=self.env, stderr=subprocess.STDOUT)

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    def stage_approved(self):
        for path in EXCEPTIONS:
            self.write(path, (ROOT / path).read_bytes())
        self.git("add", 'backend')

    def hook(self):
        return subprocess.run(["sh", str(ROOT / "scripts/pre-commit")], cwd=self.root,
                              env=self.env, capture_output=True, text=True)

    def test_exact_mirror_and_approved_test_pass(self):
        self.assertEqual(self.hook().returncode, 0)
        self.stage_approved()
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("approved test-only exceptions", result.stdout)

    def test_an_extra_edit_to_the_approved_test_fails(self):
        for path in EXCEPTIONS:
            with self.subTest(path=path):
                self.stage_approved()
                with (self.root / path).open('a') as output:
                    output.write('\n# additional unapproved change\n')
                self.git('add', path)
                self.assertNotEqual(self.hook().returncode, 0)

    def test_other_backend_changes_still_fail(self):
        self.stage_approved()
        self.write("backend/other.py", b"value = 2\n")
        self.git("add", "backend/other.py")
        self.assertNotEqual(self.hook().returncode, 0)

    def test_upstream_test_drift_requires_retiring_the_exception(self):
        self.write(TEST_PATH, self.original + b"\n# upstream changed\n")
        self.git("add", TEST_PATH)
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-qm", "upstream change")
        self.git("update-ref", "refs/remotes/upstream/main", "HEAD")
        self.stage_approved()
        self.assertNotEqual(self.hook().returncode, 0)


if __name__ == "__main__":
    unittest.main()
