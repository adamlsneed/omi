#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omi-dev-smoke-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/Omi Dev.app"
RESOURCES="$APP/Contents/Resources"
BUNDLE_RESOURCES="$RESOURCES/Omi Computer_Omi Computer.bundle"

mkdir -p "$BUNDLE_RESOURCES" "$RESOURCES/agent/dist"
cat > "$BUNDLE_RESOURCES/node" <<'NODE'
#!/bin/sh
echo "v20.0.0"
NODE
chmod +x "$BUNDLE_RESOURCES/node"
printf 'console.log("agent")\n' > "$RESOURCES/agent/dist/index.js"
cat > "$RESOURCES/.env" <<'ENV'
OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc.a.run.app
OMI_PYTHON_API_URL=https://api.omi.me
ENV

OMI_DEV_APP_PATH="$APP" OMI_DEV_SMOKE_SKIP_CODESIGN=1 bash "$SCRIPT_DIR/omi-dev-smoke.sh" >/dev/null

perl -0pi -e 's#OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc.a.run.app#OMI_DESKTOP_API_URL=http://localhost:8080#' "$RESOURCES/.env"
if OMI_DEV_APP_PATH="$APP" OMI_DEV_SMOKE_SKIP_CODESIGN=1 bash "$SCRIPT_DIR/omi-dev-smoke.sh" >/dev/null 2>&1; then
  echo "Expected smoke script to reject non-BasedHardware desktop backend" >&2
  exit 1
fi

echo "omi-dev-smoke tests passed"
