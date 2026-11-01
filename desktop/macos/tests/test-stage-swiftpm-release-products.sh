#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGE="$MACOS_DIR/scripts/stage-swiftpm-release-products.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/omi-swiftpm-products.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

fixture() {
  local root="$1" layout="$2" products resources
  if [[ "$layout" == "xcode" ]]; then
    products="$root/.build/out/Products/Release"
    resources="$products/Omi Computer_Omi Computer.bundle/Contents/Resources"
    mkdir -p "$products"
    ln -s out/Products/Release "$root/.build/release"
  else
    products="$root/.build/arm64-apple-macosx/release"
    resources="$products/Omi Computer_Omi Computer.bundle"
    mkdir -p "$products"
    ln -s arm64-apple-macosx/release "$root/.build/release"
  fi
  mkdir -p "$resources"
  for binary in "$products/Omi Computer" "$resources/node" "$resources/ffmpeg"; do
    printf '#!/bin/sh\nexit 0\n' > "$binary"
    chmod +x "$binary"
  done
  printf 'copied asset\n' > "$resources/permissions.gif"
  for framework in Sparkle onnxruntime; do
    mkdir -p "$products/$framework.framework/Versions/A"
    printf '%s\n' "$framework" > "$products/$framework.framework/Versions/A/$framework"
    ln -s A "$products/$framework.framework/Versions/Current"
    ln -s "Versions/Current/$framework" "$products/$framework.framework/$framework"
  done
}

for layout in legacy xcode; do
  root="$work/$layout"
  fixture "$root" "$layout"
  app="$root/Staged.app"
  bash "$STAGE" "$root/.build/release" "$app"
  [[ -x "$app/Contents/MacOS/Omi Computer" ]] || fail "missing main executable ($layout)"
  for framework in Sparkle onnxruntime; do
    grep -Fxq "$framework" "$app/Contents/Frameworks/$framework.framework/$framework" \
      || fail "framework or its symlinks missing ($layout, $framework)"
  done
  resource="$app/Contents/Resources/Omi Computer_Omi Computer.bundle"
  [[ -x "$resource/Contents/Resources/node" ]] || fail "Node not normalized ($layout)"
  [[ ! -f "$resource/node" ]] || fail "duplicate root Node ($layout)"
  [[ -x "$resource/ffmpeg" || -x "$resource/Contents/Resources/ffmpeg" ]] || fail "ffmpeg missing ($layout)"
  [[ -f "$resource/permissions.gif" || -f "$resource/Contents/Resources/permissions.gif" ]] || fail "other resources lost ($layout)"
  [[ -x "$root/.build/release/Omi Computer_Omi Computer.bundle/node" || "$layout" == "xcode" ]] \
    || fail "normalization mutated SwiftPM products"
done

for missing in 'Omi Computer' 'Sparkle.framework/Sparkle' 'onnxruntime.framework/onnxruntime' \
  'Omi Computer_Omi Computer.bundle/Contents/Resources/node' \
  'Omi Computer_Omi Computer.bundle/Contents/Resources/ffmpeg'; do
  root="$work/missing-$(printf '%s' "$missing" | tr '/ ' '__')"
  fixture "$root" xcode
  rm "$root/.build/release/$missing"
  if bash "$STAGE" "$root/.build/release" "$root/Staged.app" > "$root/output.log" 2>&1; then
    fail "accepted missing required product: $missing"
  fi
  grep -q 'ERROR:' "$root/output.log" || fail "missing failure diagnostic: $missing"
  [[ ! -d "$root/Staged.app" ]] || fail "partial bundle created before validating inputs"
done

# Static wiring: executing release.sh itself would sign and publish; copying is tested above.
python3 - "$MACOS_DIR/release.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert './scripts/stage-swiftpm-release-products.sh "$REL_BIN_DIR" "$APP_BUNDLE"' in text
assert 'REL_ARCH_DIR' not in text
assert 'BUNDLED_NODE="$APP_BUNDLE/Contents/Resources/Omi Computer_Omi Computer.bundle/Contents/Resources/node"' in text
PY
echo "SwiftPM release product staging tests passed"
