#!/usr/bin/env python3
"""The retired test exception must not admit any backend changes."""
import os
import runpy
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TEST_PATH = "backend/tests/unit/test_edit_tools_resilience.py"
UPSTREAM_BLOB = "086a2111e4"
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
        self.write(TEST_PATH, self.original)
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

    def hook(self):
        return subprocess.run(["sh", str(ROOT / "scripts/pre-commit")], cwd=self.root,
                              env=self.env, capture_output=True, text=True)

    def test_exact_mirror_passes(self):
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(EXCEPTIONS, {})

    def test_former_exception_changes_fail(self):
        self.write(TEST_PATH, self.original + b"\n# unapproved edit\n")
        self.git("add", TEST_PATH)
        self.assertNotEqual(self.hook().returncode, 0)

    def test_previously_approved_blob_is_rejected(self):
        old = subprocess.check_output(["git", "cat-file", "blob", "a66d38337a6f7e510c6c6144625de1750cf3d452"], cwd=ROOT)
        self.write(TEST_PATH, old)
        self.git("add", TEST_PATH)
        self.assertNotEqual(self.hook().returncode, 0)

    def test_other_backend_changes_still_fail(self):
        self.write("backend/other.py", b"value = 2\n")
        self.git("add", "backend/other.py")
        self.assertNotEqual(self.hook().returncode, 0)


if __name__ == "__main__":
    unittest.main()
