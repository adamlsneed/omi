#!/bin/bash
# Exercises scripts/release-appcast.sh: newest item first, fields carried through,
# and the file is created on first use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omi-appcast-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APPCAST="$TMP_DIR/appcast.xml"
printf 'First build.\n' > "$TMP_DIR/notes1.md"
printf 'Second build with <b>markup</b> & ampersand.\n' > "$TMP_DIR/notes2.md"

APPCAST_PUB_DATE="Thu, 04 Sep 2026 00:00:00 +0000" bash "$SCRIPT_DIR/scripts/release-appcast.sh" \
  "$APPCAST" 0.1.9 "https://example.test/omi-desktop-0.1.9.zip" 100 "sig-one" "$TMP_DIR/notes1.md" >/dev/null
APPCAST_PUB_DATE="Fri, 05 Sep 2026 00:00:00 +0000" bash "$SCRIPT_DIR/scripts/release-appcast.sh" \
  "$APPCAST" 0.1.10 "https://example.test/omi-desktop-0.1.10.zip" 200 "sig-two" "$TMP_DIR/notes2.md" >/dev/null

APPCAST="$APPCAST" python3 - <<'PY'
import os, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(os.environ["APPCAST"]).getroot()
items = root.findall("./channel/item")
assert [i.findtext("sparkle:version", namespaces=ns) for i in items] == ["0.1.10", "0.1.9"], "newest item must come first"
enc = items[0].find("enclosure")
assert enc.get("url") == "https://example.test/omi-desktop-0.1.10.zip"
assert enc.get("length") == "200"
assert enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature") == "sig-two"
assert items[0].findtext("pubDate") == "Fri, 05 Sep 2026 00:00:00 +0000"
assert "<b>markup</b> & ampersand" in items[0].findtext("description")
assert root.findtext("./channel/title") == "Omi Dev (fork)"
PY
echo "release-appcast tests passed"
