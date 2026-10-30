#!/usr/bin/env python3
"""Run the upstream logging guard against inert snapshots of fork deployments."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
INPUTS = ('backend', 'plugins', '.github/workflows', '.github/disabled-workflows')


def restore_archived_workflows(root: Path, upstream_files: set[str] | None = None) -> None:
    """Restore names only in a disposable snapshot, never in the checkout."""
    active = root / '.github/workflows'
    active.mkdir(parents=True, exist_ok=True)
    for source in (root / '.github/disabled-workflows').glob('*.yml'):
        if upstream_files is not None and f'.github/workflows/{source.name}' not in upstream_files:
            continue
        target = active / source.name
        if not target.exists():
            shutil.copy2(source, target)


def stage_current(root: Path, target: Path) -> None:
    names = subprocess.check_output(['git', 'ls-files', '-z', '--', *INPUTS], cwd=root).decode().split('\0')
    for name in filter(None, names):
        source = root / name
        if not source.is_file():
            continue
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    restore_archived_workflows(target)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    args = parser.parse_args()
    baseline = args.base
    pending = 'backend/logging_rollout_pending.json'
    if subprocess.run(['git', 'cat-file', '-e', f'{baseline}:{pending}'], cwd=ROOT,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        # This fork predates the guard's launch-binding schema. Seed its first
        # adoption from the imported migration inventory, not older debt.
        baseline = subprocess.check_output(
            ['git', 'log', '-1', '--format=%H', 'HEAD', '--', pending],
            cwd=ROOT, text=True).strip()
        subprocess.run(['git', 'cat-file', '-e', f'{baseline}:{pending}'], cwd=ROOT, check=True)
        print(f'Bootstrapping logging ratchet from imported inventory revision {baseline}', flush=True)
    with tempfile.TemporaryDirectory(prefix='omi-fork-logging-') as directory:
        current = Path(directory)
        stage_current(ROOT, current)
        git_dir = subprocess.check_output(['git', 'rev-parse', '--absolute-git-dir'], cwd=ROOT, text=True).strip()
        env = dict(os.environ, GIT_DIR=git_dir)
        env.pop('GIT_WORK_TREE', None)
        env.pop('GIT_INDEX_FILE', None)
        return subprocess.call(
            [sys.executable, str(current / 'backend/scripts/check_logging_entrypoints.py'), '--base', baseline],
            cwd=current, env=env)


if __name__ == '__main__':
    raise SystemExit(main())
