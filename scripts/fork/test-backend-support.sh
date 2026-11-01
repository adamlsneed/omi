#!/usr/bin/env bash
# Exercise the real upstream scanner and original tests in one hermetic session.
set -euo pipefail
fork_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fork_test_list="$(mktemp)"
trap 'rm -f "$fork_test_list"' EXIT
cat > "$fork_test_list" <<'TESTS'
tests/unit/test_task_integrations_sanitization.py
tests/unit/test_task_intelligence_contract_freeze.py
../scripts/fork/test_watch_source_contract.py
TESTS
export BACKEND_UNIT_TEST_FILE_LIST="$fork_test_list"
export BACKEND_PYTEST_FILE_ISOLATION=0 BACKEND_PYTEST_XDIST=0
bash "$fork_test_root/scripts/fork/backend-test-env.sh"
