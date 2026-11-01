#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 /path/to/SwiftPM/release /path/to/staged.app" >&2
  exit 2
fi
products="$1"
app="$2"
resource="$products/Omi Computer_Omi Computer.bundle"
# shellcheck source=launcher-bootstrap.sh
source "$(dirname "$0")/launcher-bootstrap.sh"

require_product() {
  echo "ERROR: required SwiftPM release product missing or unusable: $1" >&2
  exit 1
}

[[ -x "$products/Omi Computer" ]] || require_product "$products/Omi Computer"
for framework in Sparkle onnxruntime; do
  [[ -f "$products/$framework.framework/$framework" ]] \
    || require_product "$products/$framework.framework/$framework"
done
[[ -x "$resource/node" || -x "$resource/Contents/Resources/node" ]] \
  || require_product "$resource (node)"
[[ -x "$resource/ffmpeg" || -x "$resource/Contents/Resources/ffmpeg" ]] \
  || require_product "$resource (ffmpeg)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp -f "$products/Omi Computer" "$app/Contents/MacOS/Omi Computer"
for framework in Sparkle onnxruntime; do
  cp -R "$products/$framework.framework" "$app/Contents/Frameworks/"
done
cp -R "$resource" "$app/Contents/Resources/"
omi_normalize_packaged_resource_bundle "$app/Contents/Resources/$(basename "$resource")"
[[ -x "$app/Contents/Resources/$(basename "$resource")/Contents/Resources/node" ]] \
  || require_product "$app (normalized node)"
echo "Staged SwiftPM release products from $products"
