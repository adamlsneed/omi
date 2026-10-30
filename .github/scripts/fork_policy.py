"""Verify inherited source before applying the fork's upstream mirror policy."""

import argparse
from pathlib import Path
import subprocess

FORK_URLS = {'https://github.com/adamlsneed/omi', 'git@github.com:adamlsneed/omi'}
BACKEND_EXCEPTIONS = {
    'backend/tests/unit/test_episode_boundary_evidence.py': (
        '80c934ae2317078d88d8465a30ae5a49395db178',
        '0f82e7a2aa644bb86d74466b7167a723163c45a1',
    ),
    'backend/config/task_intelligence_sources_v1.json': (
        '5c848f749ee36e30da911489b14242adbc4690ba',
        '4b92533923c85af843d8db251ec5d9ea1fa4cb88',
    ),
    'backend/tests/unit/test_task_integrations_sanitization.py': (
        '7e87f5ea93c7e2930442e7bc4fde922489d20a06',
        '536ca5c7468ba0a0f702376f4051318d97861ddf',
    ),
    'backend/tests/unit/test_edit_tools_resilience.py': (
        '32acf6628b479ce2c9d6b9b5fac81b265386d8a7',
        'a66d38337a6f7e510c6c6144625de1750cf3d452',
    ),
}


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.PIPE).strip()


def upstream_base(root):
    if not (root / '.git').exists():
        return None
    origin = subprocess.run(['git', 'remote', 'get-url', 'origin'], cwd=root, capture_output=True, text=True)
    if origin.stdout.strip().removesuffix('.git') not in FORK_URLS:
        return None
    incoming = subprocess.run(['git', 'rev-parse', '-q', '--verify', 'MERGE_HEAD'],
                              cwd=root, capture_output=True, text=True)
    if incoming.returncode == 0:
        revision = incoming.stdout.strip()
        ancestor = subprocess.run(['git', 'merge-base', '--is-ancestor', revision, 'upstream/main'], cwd=root)
        if ancestor.returncode == 0:
            return revision
    return git(root, 'merge-base', 'HEAD', 'upstream/main')


def mirrors_upstream(root, path):
    base = upstream_base(root)
    if base is None:
        return False
    try:
        original = git(root, 'rev-parse', f'{base}:{path}')
        current = git(root, 'hash-object', '--', path)
    except subprocess.CalledProcessError:
        return False
    return original == current


def verify_backend(root, cached=False):
    base = upstream_base(root)
    if base is None:
        raise ValueError('Backend mirror verification requires the adamlsneed/omi fork.')
    options = ['--cached'] if cached else []
    result = subprocess.run(
        ['git', 'diff', *options, '--quiet', base, '--', 'backend/',
         *(f':(exclude){path}' for path in BACKEND_EXCEPTIONS)], cwd=root,
    )
    if result.returncode:
        raise ValueError('Backend differs from upstream outside the approved test-only exceptions.')
    for path, (upstream_blob, approved_blob) in BACKEND_EXCEPTIONS.items():
        original = git(root, 'rev-parse', f'{base}:{path}')
        current = git(root, 'rev-parse', f':{path}') if cached else git(root, 'hash-object', '--', path)
        if current == original:
            continue
        if (original, current) != (upstream_blob, approved_blob):
            raise ValueError(f'Unapproved backend test bytes: {path}')
    print(f'Verified upstream backend mirror and approved test-only exceptions ({base}).')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cached', action='store_true')
    args = parser.parse_args()
    verify_backend(Path(__file__).resolve().parents[2], cached=args.cached)
