#!/bin/bash
# Prepends one Sparkle <item> for a fork desktop release to an appcast.xml,
# creating the file when it does not exist. release.sh calls this after
# signing the zip; tests/test-release-appcast.sh exercises it directly.
#
# Usage: release-appcast.sh <appcast.xml> <version> <asset-url> <length> <ed-signature> <notes-file>
set -euo pipefail

APPCAST="$1"; VERSION="$2"; ASSET_URL="$3"; LENGTH="$4"; SIGNATURE="$5"; NOTES_FILE="$6"
PUB_DATE="${APPCAST_PUB_DATE:-$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')}"
MIN_SYSTEM="${APPCAST_MIN_SYSTEM_VERSION:-14.0}"

if [ ! -f "$APPCAST" ]; then
  cat > "$APPCAST" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Omi Dev (fork)</title>
    <link>https://github.com/adamlsneed/omi</link>
    <description>Notarized fork builds of the Omi desktop app.</description>
  </channel>
</rss>
XML
fi

APPCAST="$APPCAST" VERSION="$VERSION" ASSET_URL="$ASSET_URL" LENGTH="$LENGTH" SIGNATURE="$SIGNATURE" \
NOTES_FILE="$NOTES_FILE" PUB_DATE="$PUB_DATE" MIN_SYSTEM="$MIN_SYSTEM" python3 - <<'PY'
import os, pathlib, xml.sax.saxutils as su
p = pathlib.Path(os.environ["APPCAST"]); s = p.read_text()
notes = pathlib.Path(os.environ["NOTES_FILE"]).read_text().strip().replace("]]>", "]]]]><![CDATA[>")
v = os.environ["VERSION"]
item = f"""    <item>
      <title>Omi desktop (fork) {v}</title>
      <pubDate>{os.environ["PUB_DATE"]}</pubDate>
      <sparkle:version>{v}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{os.environ["MIN_SYSTEM"]}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{su.quoteattr(os.environ["ASSET_URL"])[1:-1]}" length="{os.environ["LENGTH"]}" type="application/octet-stream" sparkle:edSignature="{os.environ["SIGNATURE"]}"/>
    </item>
"""
marker = "  <channel>\n"
head, sep, tail = s.partition(marker)
if not sep:
    raise SystemExit(f"{p}: no <channel> element")
# Skip the channel header (title/link/description) so the newest item comes first.
lines = tail.split("\n")
i = 0
while i < len(lines) and lines[i].strip().startswith(("<title>", "<link>", "<description>")):
    i += 1
tail = "\n".join(lines[:i]) + "\n" + item + "\n".join(lines[i:])
p.write_text(head + sep + tail)
PY
echo "    appcast: added $VERSION to $APPCAST"
