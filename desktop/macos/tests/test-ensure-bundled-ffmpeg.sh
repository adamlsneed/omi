#!/usr/bin/env bash
# Fork: ensure-bundled-ffmpeg.sh fetches the resource once and leaves a working copy alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/omi-ensure-ffmpeg-test.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# A fake archive: a script that answers -version, which is all the helper probes.
mkdir -p "$tmpdir/archive/ffmpeg-fake"
cat > "$tmpdir/archive/ffmpeg-fake/ffmpeg" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "-version" ] && echo "ffmpeg version test" && exit 0
exit 1
FAKE
chmod +x "$tmpdir/archive/ffmpeg-fake/ffmpeg"
(cd "$tmpdir/archive" && zip -q -r "$tmpdir/ffmpeg.zip" ffmpeg-fake)

resource="$tmpdir/Resources/ffmpeg"

# 1. Missing resource: downloaded from the configured URL and made executable.
OMI_FFMPEG_RESOURCE_PATH="$resource" OMI_FFMPEG_DOWNLOAD_URL="file://$tmpdir/ffmpeg.zip" \
  bash "$MACOS_DIR/scripts/ensure-bundled-ffmpeg.sh" >"$tmpdir/first.out" 2>&1 \
  || fail "first run failed: $(cat "$tmpdir/first.out")"
[ -x "$resource" ] || fail "resource was not installed as an executable"
grep -q "bundled ffmpeg ready" "$tmpdir/first.out" || fail "first run did not report a download"

# 2. Present and runnable: no download, even with an unreachable URL.
OMI_FFMPEG_RESOURCE_PATH="$resource" OMI_FFMPEG_DOWNLOAD_URL="file://$tmpdir/does-not-exist.zip" \
  bash "$MACOS_DIR/scripts/ensure-bundled-ffmpeg.sh" >"$tmpdir/second.out" 2>&1 \
  || fail "second run failed: $(cat "$tmpdir/second.out")"
grep -q "bundled ffmpeg present" "$tmpdir/second.out" || fail "second run re-downloaded a working resource"

# 3. Present but broken: replaced from the archive.
printf '#!/usr/bin/env bash\nexit 1\n' > "$resource"
OMI_FFMPEG_RESOURCE_PATH="$resource" OMI_FFMPEG_DOWNLOAD_URL="file://$tmpdir/ffmpeg.zip" \
  bash "$MACOS_DIR/scripts/ensure-bundled-ffmpeg.sh" >"$tmpdir/third.out" 2>&1 \
  || fail "third run failed: $(cat "$tmpdir/third.out")"
"$resource" -version >/dev/null 2>&1 || fail "broken resource was not replaced"

echo "ensure-bundled-ffmpeg tests passed"
