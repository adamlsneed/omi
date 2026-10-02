#!/bin/bash
# Fork: make sure the gitignored ffmpeg resource exists before a desktop build.
#
# Package.swift bundles everything under Desktop/Sources/Resources, and
# scripts/audit-desktop-bundle-deps.sh (run by run.sh) fails a bundle without
# ffmpeg. Upstream's Codemagic lane downloads the binary in CI; the fork builds
# locally, so release.sh and scripts/fork/redeploy-omi-dev.sh call this first.
# Same source as codemagic.yaml ("Prepare universal ffmpeg"), host arch only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FFMPEG_RESOURCE="${OMI_FFMPEG_RESOURCE_PATH:-$DESKTOP_DIR/Desktop/Sources/Resources/ffmpeg}"
HOST_ARCH="$(uname -m)"

case "$HOST_ARCH" in
  arm64) DOWNLOAD_ARCH="arm64" ;;
  x86_64) DOWNLOAD_ARCH="amd64" ;;
  *) echo "ensure-bundled-ffmpeg: unsupported host arch $HOST_ARCH" >&2; exit 1 ;;
esac
DOWNLOAD_URL="${OMI_FFMPEG_DOWNLOAD_URL:-https://ffmpeg.martin-riedl.de/redirect/latest/macos/$DOWNLOAD_ARCH/release/ffmpeg.zip}"

ffmpeg_is_runnable() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  local description
  description="$(file "$binary" 2>/dev/null || true)"
  case "$description" in
    *"$HOST_ARCH"*|*"universal binary"*|*"script text"*) ;;
    *) return 1 ;;
  esac
  "$binary" -version >/dev/null 2>&1
}

if ffmpeg_is_runnable "$FFMPEG_RESOURCE"; then
  echo "bundled ffmpeg present: $FFMPEG_RESOURCE"
  exit 0
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/omi-ffmpeg.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

echo "downloading ffmpeg ($DOWNLOAD_ARCH) from $DOWNLOAD_URL"
curl -fsSL -o "$tmpdir/ffmpeg.zip" "$DOWNLOAD_URL"
unzip -q -o "$tmpdir/ffmpeg.zip" -d "$tmpdir/unpacked"
downloaded="$(find "$tmpdir/unpacked" -type f -name ffmpeg | head -1)"
[ -n "$downloaded" ] || { echo "ensure-bundled-ffmpeg: no ffmpeg binary in the archive" >&2; exit 1; }

mkdir -p "$(dirname "$FFMPEG_RESOURCE")"
cp -f "$downloaded" "$FFMPEG_RESOURCE"
chmod +x "$FFMPEG_RESOURCE"
if command -v xattr >/dev/null 2>&1; then xattr -cr "$FFMPEG_RESOURCE" 2>/dev/null || true; fi
# Ad hoc now; release.sh and run.sh re-sign every executable under Resources.
if [[ "$(file "$FFMPEG_RESOURCE" 2>/dev/null || true)" == *"Mach-O"* ]] && command -v codesign >/dev/null 2>&1; then
  codesign -f -s - "$FFMPEG_RESOURCE"
fi

ffmpeg_is_runnable "$FFMPEG_RESOURCE" || { echo "ensure-bundled-ffmpeg: downloaded ffmpeg does not run on $HOST_ARCH" >&2; exit 1; }
echo "bundled ffmpeg ready: $FFMPEG_RESOURCE ($(file "$FFMPEG_RESOURCE" | sed 's/.*: //'))"
