#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGER="$SCRIPT_DIR/../scripts/embed-app-intents-metadata.sh"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/Desktop/.build" "$FIXTURE/Omi.app/Contents/Resources" "$FIXTURE/bin"
cat > "$FIXTURE/package.json" <<'JSON'
{"targets":[{"name":"Omi Computer","sources":[]}]}
JSON
cat > "$FIXTURE/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" = 'swift package' ]]; then
  cat "$SIRI_TEST_PACKAGE_DESCRIPTION"
elif [[ "${1:-}" = appintentsmetadataprocessor ]]; then
  shift
  output=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" = --output ]]; then output="$2"; shift; fi
    shift
  done
  mkdir -p "$output/Metadata.appintents"
  cp "$SIRI_TEST_METADATA" "$output/Metadata.appintents/extract.actionsdata"
elif [[ "$*" = '--sdk macosx --show-sdk-path' ]]; then
  echo /fixture/MacOSX.sdk
else
  echo "unexpected xcrun invocation: $*" >&2
  exit 99
fi
SH
chmod +x "$FIXTURE/bin/xcrun"
export PATH="$FIXTURE/bin:$PATH"
export SIRI_TEST_PACKAGE_DESCRIPTION="$FIXTURE/package.json"

"$PACKAGER" "$FIXTURE/Desktop" "$FIXTURE/Omi.app" Release arm64 --expect-absent > "$FIXTURE/absent.out" 2>&1 || {
  cat "$FIXTURE/absent.out" >&2
  echo 'FAIL: stable metadata check must work without constant-value files' >&2
  exit 1
}
grep -Fq 'Xcode 26.6 bundle has no Metadata.appintents' "$FIXTURE/absent.out" || {
  echo 'FAIL: stable metadata check did not prove bundle absence' >&2
  exit 1
}

if "$PACKAGER" "$FIXTURE/Desktop" "$FIXTURE/Omi.app" Release arm64 --require-siri > "$FIXTURE/required.out" 2>&1; then
  echo 'FAIL: Siri metadata packaging accepted missing constant-value files' >&2
  exit 1
fi
grep -Fq 'Omi Computer constant-value files missing; build with -Xswiftc -emit-const-values' "$FIXTURE/required.out" || {
  cat "$FIXTURE/required.out" >&2
  echo 'FAIL: Siri metadata packaging gave no missing-constants diagnostic' >&2
  exit 1
}

mkdir -p "$FIXTURE/Desktop/.build/Release/Omi Computer.build/Objects-normal/arm64" "$FIXTURE/Desktop/Sources"
touch "$FIXTURE/Desktop/.build/Release/Omi Computer.build/Objects-normal/arm64/SiriIntents.swiftconstvalues"
cat > "$FIXTURE/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf 'Xcode 27.1\nBuild version 27A9275\n'
SH
cat > "$FIXTURE/bin/xcode-select" <<'SH'
#!/usr/bin/env bash
echo /fixture/Xcode.app/Contents/Developer
SH
chmod +x "$FIXTURE/bin/xcodebuild" "$FIXTURE/bin/xcode-select"
export SIRI_TEST_METADATA="$FIXTURE/metadata.json"
printf '%s\n' '{"actions":{"RememberIntent":{}},"entities":{"ConversationEntity":{}}}' > "$SIRI_TEST_METADATA"
"$PACKAGER" "$FIXTURE/Desktop" "$FIXTURE/Omi.app" Release arm64 > "$FIXTURE/valid.out" 2>&1 || {
  cat "$FIXTURE/valid.out" >&2
  echo 'FAIL: valid Siri release metadata was not packaged' >&2
  exit 1
}
cmp "$SIRI_TEST_METADATA" "$FIXTURE/Omi.app/Contents/Resources/Metadata.appintents/extract.actionsdata"
cp "$SIRI_TEST_METADATA" "$FIXTURE/valid-metadata.json"
printf '%s\n' '{"actions":{"RememberIntent":{}},"entities":{}}' > "$SIRI_TEST_METADATA"
if "$PACKAGER" "$FIXTURE/Desktop" "$FIXTURE/Omi.app" Release arm64 > "$FIXTURE/invalid.out" 2>&1; then
  echo 'FAIL: Siri release metadata accepted a missing conversation entity' >&2
  exit 1
fi
grep -Fq 'App Intents metadata missing entities ConversationEntity' "$FIXTURE/invalid.out"
cmp "$FIXTURE/valid-metadata.json" "$FIXTURE/Omi.app/Contents/Resources/Metadata.appintents/extract.actionsdata"

echo 'metadata packager validates Siri release contents before replacing bundled metadata'
