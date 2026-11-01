#!/usr/bin/env bash
# Run an upstream backend test command with fork-only test registration.
set -euo pipefail
fork_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PYTHONPATH="$fork_test_root/scripts/fork${PYTHONPATH:+:$PYTHONPATH}"
export PYTEST_ADDOPTS="${PYTEST_ADDOPTS:+$PYTEST_ADDOPTS }-p omi_fork_pytest"
if [ "$#" -eq 0 ]; then
  set -- bash "$fork_test_root/backend/test.sh"
fi
exec "$@"
