#!/usr/bin/env python3
"""Run upstream isolation checks with the proven unreachable Jinja2 stub registered."""

import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/scripts'))
from fork_policy import git, mirrors_upstream
from git_bash import bash_executable, bash_path

TEST = 'backend/tests/unit/test_task_integrations_sanitization.py'
UPSTREAM_BLOB = '7e87f5ea93c7e2930442e7bc4fde922489d20a06'


def require_preload(root):
    plugin = ast.parse((root / 'scripts/fork/omi_fork_pytest.py').read_text())
    if not any(isinstance(node, ast.Import) and any(alias.name == 'jinja2' for alias in node.names)
               for node in plugin.body):
        raise ValueError('fork pytest plugin must import real Jinja2 unconditionally before test collection')
    wrapper = (root / 'scripts/fork/backend-test-env.sh').read_text()
    if not re.search(r'^export PYTEST_ADDOPTS=.*-p omi_fork_pytest', wrapper, re.MULTILINE):
        raise ValueError('fork backend test environment must load omi_fork_pytest')
    if not re.search(r'^export PYTHONPATH="\$fork_test_root/scripts/fork', wrapper, re.MULTILINE):
        raise ValueError('fork backend test environment must expose the fork pytest plugin')
    bash = bash_executable()
    probe = (
        'import importlib.util,json,os; '
        'spec=importlib.util.find_spec("omi_fork_pytest"); '
        'print(json.dumps({"options":os.environ.get("PYTEST_ADDOPTS",""),'
        '"plugin":spec.origin if spec else None}))'
    )
    try:
        environment = json.loads(subprocess.check_output(
            [bash, bash_path(root / 'scripts/fork/backend-test-env.sh', bash),
             bash_path(Path(sys.executable), bash), '-c', probe],
            cwd=root, env={**os.environ, 'PYTEST_ADDOPTS': '', 'PYTHONPATH': ''},
            text=True, timeout=15,
        ))
    except (subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise ValueError('fork backend test child environment probe failed') from error
    if (shlex.split(environment['options']) != ['-p', 'omi_fork_pytest']
            or not environment['plugin']
            or Path(environment['plugin']).resolve() != (root / 'scripts/fork/omi_fork_pytest.py').resolve()):
        raise ValueError('fork backend test child must receive the registered preload plugin')
    for name in ('scripts/pre-push', 'scripts/backend-ratchet-preflight',
                 '.github/workflows/backend-unit-tests.yml'):
        commands = [line for line in (root / name).read_text().splitlines()
                    if not line.lstrip().startswith(('#', 'echo '))
                    and re.search(r'\bbash (?:test\.sh|scripts/run-(?:unit|slow-guardrails)-ci\.sh)\b', line)]
        if not commands or any('bash ../scripts/fork/backend-test-env.sh bash ' not in line for line in commands):
            raise ValueError(f'{name} must run backend tests through the fork preload environment')
    support = (root / 'scripts/fork/test-backend-support.sh').read_text()
    if not re.search(r'^bash "\$fork_test_root/scripts/fork/backend-test-env.sh"', support, re.MULTILINE):
        raise ValueError('fork backend regression suite must use the preload environment')


def run(root, *, files=None, base=None):
    if not mirrors_upstream(root, TEST) or git(root, 'hash-object', '--', TEST) != UPSTREAM_BLOB:
        raise ValueError('Jinja2 stub registration requires the exact reviewed upstream test bytes')
    require_preload(root)
    path = root / 'backend/scripts/check_module_stub_pollution.py'
    spec = importlib.util.spec_from_file_location('upstream_module_isolation', path)
    checker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checker)
    # Validate the real legacy inventory before creating the process-local addition.
    if base and checker._check_monotonic(checker.DEFAULT_ALLOWLIST, base):
        return 1
    with tempfile.TemporaryDirectory(prefix='omi-fork-module-isolation-') as directory:
        allowlist = Path(directory) / 'allowlist'
        entries = checker._load_allowlist(checker.DEFAULT_ALLOWLIST)
        allowlist.write_text('\n'.join(sorted(entries | {TEST})) + '\n')
        arguments = ['--allowlist', str(allowlist)]
        if files:
            arguments += ['--files', str(files)]
        print('Verified inherited Jinja2 stub is unreachable under all fork backend test runners.', flush=True)
        return checker.main(arguments)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--files', type=Path)
    parser.add_argument('--check-allowlist-monotonic')
    args = parser.parse_args()
    try:
        return run(ROOT, files=args.files, base=args.check_allowlist_monotonic)
    except (ValueError, OSError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
