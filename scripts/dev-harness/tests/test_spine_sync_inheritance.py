"""Fork policy (adamlsneed/omi): spine revisions inherited through an upstream
sync merge are not the sync PR's own revision."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("check_spine_contracts", ROOT / "scripts" / "check_spine_contracts.py")
spine = importlib.util.module_from_spec(SPEC)
sys.modules["check_spine_contracts"] = spine
SPEC.loader.exec_module(spine)

PATH = "contracts/spine/revisions/009-example.json"
ENV = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}


def _git(root: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-C", str(root), *args],
        text=True,
        env=ENV,
    ).strip()


def _commit(root: Path, path: str, text: str, message: str) -> None:
    file = root / path
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(text)
    _git(root, "add", path)
    _git(root, "commit", "-q", "-m", message)


def _sync_repo(tmp_path: Path) -> tuple[Path, str]:
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    _commit(root, "README", "shared history\n", "shared history")
    _git(root, "checkout", "-q", "-b", "upstream")
    _commit(root, PATH, '{"revision": 9}\n', "upstream spine revision")
    _commit(root, "app/lib/feature.dart", "// upstream implementation\n", "upstream implementation")
    _git(root, "checkout", "-q", "main")
    # The fork's main carries its own commits, so upstream never contains the PR base.
    _commit(root, "FORK", "fork change\n", "fork change")
    base = _git(root, "rev-parse", "HEAD")
    _git(root, "checkout", "-q", "-b", "sync")
    _git(root, "merge", "-q", "--no-ff", "--no-edit", "upstream")
    return root, base


def test_revision_inherited_through_a_sync_merge_is_not_the_prs_revision(tmp_path):
    root, base = _sync_repo(tmp_path)
    assert spine.inherited_from_sync_merge(root, base, PATH)


def test_a_fork_edit_to_an_inherited_revision_is_still_the_prs_revision(tmp_path):
    root, base = _sync_repo(tmp_path)
    (root / PATH).write_text('{"revision": 9, "fork": true}\n')
    assert not spine.inherited_from_sync_merge(root, base, PATH)


def test_a_revision_with_no_sync_merge_is_the_prs_revision(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    _commit(root, "README", "base\n", "base")
    base = _git(root, "rev-parse", "HEAD")
    _git(root, "checkout", "-q", "-b", "feature")
    _commit(root, PATH, '{"revision": 9}\n', "builder revision")
    assert not spine.inherited_from_sync_merge(root, base, PATH)
