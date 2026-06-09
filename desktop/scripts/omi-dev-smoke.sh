#!/bin/bash
set -euo pipefail

APP_PATH="${OMI_DEV_APP_PATH:-/Applications/Omi Dev.app}"
RESOURCES="$APP_PATH/Contents/Resources"
RESOURCE_BUNDLE="$RESOURCES/Omi Computer_Omi Computer.bundle"
NODE="$RESOURCE_BUNDLE/node"
AGENT_SCRIPT="$RESOURCES/agent/dist/index.js"
ENV_FILE="$RESOURCES/.env"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

check_file() {
  local path="$1"
  local label="$2"
  [ -f "$path" ] || fail "$label missing: $path"
  echo "ok: $label"
}

check_executable() {
  local path="$1"
  local label="$2"
  [ -x "$path" ] || fail "$label missing or not executable: $path"
  echo "ok: $label"
}

[ -d "$APP_PATH" ] || fail "Omi Dev app not found: $APP_PATH"
[ -d "$RESOURCES" ] || fail "Resources directory missing: $RESOURCES"

check_executable "$NODE" "bundled Node.js"
"$NODE" --version >/dev/null || fail "bundled Node.js did not run: $NODE"
check_file "$AGENT_SCRIPT" "agent runtime"
check_file "$ENV_FILE" "backend environment"

grep -Eq '^OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc\.a\.run\.app/?$' "$ENV_FILE" \
  || fail "OMI_DESKTOP_API_URL must point at BasedHardware desktop backend"
grep -Eq '^OMI_PYTHON_API_URL=https://api\.omi\.me/?$' "$ENV_FILE" \
  || fail "OMI_PYTHON_API_URL must point at BasedHardware Python API"
echo "ok: BasedHardware hosted backend URLs"

if [ "${OMI_DEV_SMOKE_SKIP_CODESIGN:-0}" != "1" ]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null \
    || fail "codesign verification failed"
  echo "ok: codesign"
fi

if [ "${OMI_DEV_SMOKE_LAUNCH:-0}" = "1" ]; then
  open -a "$APP_PATH"
  sleep "${OMI_DEV_SMOKE_LAUNCH_WAIT_SECONDS:-5}"
  pgrep -fl 'Omi Dev.app|Omi Computer' >/dev/null \
    || fail "Omi Dev did not appear to launch"
  echo "ok: launch"
fi

echo "Omi Dev smoke checks passed"
