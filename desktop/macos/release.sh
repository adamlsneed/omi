#!/usr/bin/env bash
# Fork-only release builder for the Omi desktop app.
#
# Produces a signed + notarized release build of the SAME bundle the local dev
# install uses (com.omi.desktop-dev / "Omi Dev"), publishes it as a GitHub
# Release asset, and updates the Homebrew cask in adamlsneed/homebrew-omi.
#
# This is intentionally separate from run.sh (which is an interactive dev runner
# that builds -c debug, signs with the debug entitlements, and never exits). The
# two share assembly logic; keep them in sync when run.sh's assembly changes.
#
# Why a dedicated release path:
#   - Builds -c release (optimized) instead of debug.
#   - Signs with Omi-Release.entitlements, which omits get-task-allow (Apple
#     notarization HARD-rejects it) and com.apple.developer.applesignin (team-
#     coupled to BasedHardware's account, not 66K48S8RD4). That entitlement set
#     is what makes notarization succeed under your own Developer ID.
#   - Notarizes + staples so the app launches cleanly on your other Macs.
#
# Prereqs (one-time):
#   - Developer ID Application cert in your keychain (you have 66K48S8RD4).
#   - notarytool credentials stored as a keychain profile named "omi-notary":
#       xcrun notarytool store-credentials omi-notary \
#         --apple-id <you@example.com> --team-id 66K48S8RD4 \
#         --password <app-specific-password>
#   - gh authenticated (gh auth status) for publishing.
#
# Usage:
#   ./release.sh <version>            # e.g. ./release.sh 0.1.0
#   SKIP_NOTARIZE=1 ./release.sh ...  # build+sign only (local smoke test)
#   SKIP_PUBLISH=1  ./release.sh ...  # build+sign+notarize, no GitHub/cask push

set -euo pipefail
cd "$(dirname "$0")"

# --- Version resolution (explicit, or --bump from the latest published tag) ---
latest_version() {
  # Highest existing desktop-fork-v* tag on origin, as bare x.y.z.
  git ls-remote --tags origin 'desktop-fork-v*' 2>/dev/null \
    | sed -E 's#.*refs/tags/desktop-fork-v##; s/\^\{\}$//' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}
bump_version() { # <x.y.z> <patch|minor|major>
  local major minor patch
  IFS=. read -r major minor patch <<< "${1#v}"
  case "$2" in
    major) echo "$((major + 1)).0.0";;
    minor) echo "$major.$((minor + 1)).0";;
    *)     echo "$major.$minor.$((patch + 1))";;
  esac
}

if [ "${1:-}" = "--bump" ]; then
  CUR="$(latest_version)"
  [ -n "$CUR" ] || { echo "ERROR: --bump found no existing desktop-fork-v* release; pass an explicit version for the first one." >&2; exit 2; }
  VERSION="$(bump_version "$CUR" "${2:-patch}")"
  echo "==> --bump ${2:-patch}: $CUR -> $VERSION"
elif [ -n "${1:-}" ]; then
  VERSION="${1#v}"
else
  echo "Usage: ./release.sh <version>                    (e.g. ./release.sh 0.1.1)" >&2
  echo "       ./release.sh --bump [patch|minor|major]   (default: patch; derives next from latest release)" >&2
  exit 2
fi

# --- Config (kept identical to the existing install so auth/state carry over) ---
APP_NAME="Omi Dev"
BUNDLE_ID="com.omi.desktop-dev"
BINARY_NAME="Omi Computer"
URL_SCHEME="omi-dev"
NOTARY_PROFILE="${NOTARY_PROFILE:-omi-notary}"
GH_REPO="${GH_REPO:-adamlsneed/omi}"
TAP_REPO="${TAP_REPO:-adamlsneed/homebrew-omi}"
TAG="desktop-fork-v${VERSION}"

# Production hosted backends (BasedHardware) — same endpoints run.sh --yolo uses.
OMI_DESKTOP_API_URL="${OMI_DESKTOP_API_URL:-https://desktop-backend-hhibjajaja-uc.a.run.app}"
OMI_PYTHON_API_URL="${OMI_PYTHON_API_URL:-https://api.omi.me}"

AGENT_DIR="agent"
PI_MONO_EXT_DIR="pi-mono-extension"
BACKEND_DIR="Backend-Rust"
STAGING="$(pwd)/.build/release-stage"
APP_BUNDLE="$STAGING/$APP_NAME.app"
DIST_DIR="$(pwd)/.build/dist"
ZIP_PATH="$DIST_DIR/omi-desktop-${VERSION}.zip"

step() { echo "==> $*"; }

# --- Build ---
step "Building agent (npm ci + tsc)"
(cd "$AGENT_DIR" && npm ci && npm run build)

step "Preparing bundled Node.js runtime"
bash scripts/prepare-node-resource.sh

step "Building Swift app (swift build -c release)"
xcrun swift build -c release --package-path Desktop

REL_BIN_DIR="Desktop/.build/release"
REL_ARCH_DIR="Desktop/.build/arm64-apple-macosx/release"

# --- Assemble bundle (mirrors run.sh; see note above) ---
step "Assembling $APP_BUNDLE"
rm -rf "$STAGING"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp -f "$REL_BIN_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

for fw in Sparkle Sentry onnxruntime; do
  if [ -d "$REL_ARCH_DIR/$fw.framework" ]; then
    rm -rf "$APP_BUNDLE/Contents/Frameworks/$fw.framework"
    cp -R "$REL_ARCH_DIR/$fw.framework" "$APP_BUNDLE/Contents/Frameworks/"
  fi
done

# libwebp (+ libsharpyuv) with @rpath load-path rewriting
WEBP_LIB=""
if command -v pkg-config >/dev/null 2>&1; then
  d="$(pkg-config --variable=libdir libwebp 2>/dev/null || true)"
  [ -n "$d" ] && WEBP_LIB="$d/libwebp.7.dylib"
fi
[ -f "$WEBP_LIB" ] || for c in /opt/homebrew/lib/libwebp.7.dylib /usr/local/lib/libwebp.7.dylib; do
  [ -f "$c" ] && WEBP_LIB="$c" && break
done
if [ -f "$WEBP_LIB" ]; then
  cp "$WEBP_LIB" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
  SHARPYUV_LIB="$(dirname "$WEBP_LIB")/libsharpyuv.0.dylib"
  if [ -f "$SHARPYUV_LIB" ]; then
    cp "$SHARPYUV_LIB" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
    install_name_tool -id "@rpath/libsharpyuv.0.dylib" "$APP_BUNDLE/Contents/Frameworks/libsharpyuv.0.dylib"
    for p in "$SHARPYUV_LIB" /opt/homebrew/opt/webp/lib/libsharpyuv.0.dylib /opt/homebrew/lib/libsharpyuv.0.dylib /usr/local/opt/webp/lib/libsharpyuv.0.dylib /usr/local/lib/libsharpyuv.0.dylib; do
      install_name_tool -change "$p" "@rpath/libsharpyuv.0.dylib" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib" 2>/dev/null || true
    done
  fi
  install_name_tool -id "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/Frameworks/libwebp.7.dylib"
  for p in "$WEBP_LIB" /opt/homebrew/opt/webp/lib/libwebp.7.dylib /opt/homebrew/lib/libwebp.7.dylib /usr/local/opt/webp/lib/libwebp.7.dylib /usr/local/lib/libwebp.7.dylib; do
    install_name_tool -change "$p" "@rpath/libwebp.7.dylib" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true
  done
fi

step "Writing Info.plist (version $VERSION)"
cp -f Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$APP_BUNDLE/Contents/Info.plist"; }
pb "Set :CFBundleExecutable $BINARY_NAME"
pb "Set :CFBundleIdentifier $BUNDLE_ID"
pb "Set :CFBundleName $APP_NAME"
pb "Set :CFBundleDisplayName $APP_NAME"
pb "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $URL_SCHEME"
pb "Set :CFBundleShortVersionString $VERSION" 2>/dev/null || pb "Add :CFBundleShortVersionString string $VERSION"
pb "Set :CFBundleVersion $VERSION" 2>/dev/null || pb "Add :CFBundleVersion string $VERSION"

step "Copying Firebase config"
if [ -f "Desktop/Sources/GoogleService-Info-Dev.plist" ]; then
  cp -f Desktop/Sources/GoogleService-Info-Dev.plist "$APP_BUNDLE/Contents/Resources/GoogleService-Info.plist"
else
  cp -f Desktop/Sources/GoogleService-Info.plist "$APP_BUNDLE/Contents/Resources/"
fi
/usr/libexec/PlistBuddy -c "Set :BUNDLE_ID $BUNDLE_ID" "$APP_BUNDLE/Contents/Resources/GoogleService-Info.plist" 2>/dev/null || true

step "Copying resource bundle + bundled Node"
RESOURCE_BUNDLE="$REL_ARCH_DIR/Omi Computer_Omi Computer.bundle"
[ -d "$RESOURCE_BUNDLE" ] && cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
BUNDLED_NODE="$APP_BUNDLE/Contents/Resources/Omi Computer_Omi Computer.bundle/node"
if [ ! -x "$BUNDLED_NODE" ] && [ -x "Desktop/Sources/Resources/node" ]; then
  mkdir -p "$(dirname "$BUNDLED_NODE")"; cp -f "Desktop/Sources/Resources/node" "$BUNDLED_NODE"; chmod +x "$BUNDLED_NODE"
fi
[ -x "$BUNDLED_NODE" ] || { echo "ERROR: bundled node missing at $BUNDLED_NODE (run scripts/prepare-node-resource.sh)"; exit 1; }

step "Copying agent + pi-mono-extension"
mkdir -p "$APP_BUNDLE/Contents/Resources/agent"
cp -Rf "$AGENT_DIR/dist" "$APP_BUNDLE/Contents/Resources/agent/"
cp -f "$AGENT_DIR/package.json" "$APP_BUNDLE/Contents/Resources/agent/"
cp -Rf "$AGENT_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/agent/"
mkdir -p "$APP_BUNDLE/Contents/Resources/pi-mono-extension"
cp -f "$PI_MONO_EXT_DIR/index.ts" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/"
cp -f "$PI_MONO_EXT_DIR/package.json" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/"
rm -rf "$APP_BUNDLE/Contents/Resources/pi-mono-extension/node_modules"
ln -s "../agent/node_modules" "$APP_BUNDLE/Contents/Resources/pi-mono-extension/node_modules"

step "Writing bundled .env (hosted backends)"
ENV_OUT="$APP_BUNDLE/Contents/Resources/.env"
# Fall back to the proven .env from the currently-installed build so the release
# inherits working auth config (same bundle id) when the gitignored source
# .env.app* / Backend-Rust/.env aren't present.
INSTALLED_ENV="/Applications/$APP_NAME.app/Contents/Resources/.env"
if [ -f ".env.app.dev" ]; then cp -f .env.app.dev "$ENV_OUT"
elif [ -f ".env.app" ]; then cp -f .env.app "$ENV_OUT"
elif [ -f "$INSTALLED_ENV" ]; then cp -f "$INSTALLED_ENV" "$ENV_OUT"
else touch "$ENV_OUT"; fi
set_env() { # key value
  if grep -q "^$1=" "$ENV_OUT"; then sed -i '' "s|^$1=.*|$1=$2|" "$ENV_OUT"; else echo "$1=$2" >> "$ENV_OUT"; fi
}
set_env OMI_DESKTOP_API_URL "$OMI_DESKTOP_API_URL"
set_env OMI_PYTHON_API_URL "$OMI_PYTHON_API_URL"
if ! grep -q "^FIREBASE_API_KEY=" "$ENV_OUT"; then
  KEY="${FIREBASE_API_KEY:-}"
  [ -z "$KEY" ] && [ -f "$BACKEND_DIR/.env" ] && KEY=$(grep "^FIREBASE_API_KEY=" "$BACKEND_DIR/.env" | head -1 | cut -d= -f2-)
  [ -z "$KEY" ] && [ -f "$INSTALLED_ENV" ] && KEY=$(grep "^FIREBASE_API_KEY=" "$INSTALLED_ENV" | head -1 | cut -d= -f2-)
  [ -n "$KEY" ] && echo "FIREBASE_API_KEY=$KEY" >> "$ENV_OUT" || echo "WARNING: FIREBASE_API_KEY not found — auth may fail" >&2
fi

cp -f omi_icon.icns "$APP_BUNDLE/Contents/Resources/OmiIcon.icns" 2>/dev/null || true
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
# No provisioning profile: release entitlements drop applesignin, so none is needed.

# --- Sign (Developer ID + hardened runtime + secure timestamp, inside-out) ---
# Notarization requires EVERY Mach-O (node native .node modules, bundled dylibs,
# Sparkle's nested Updater.app/XPC helpers) signed with Developer ID + hardened
# runtime + a secure timestamp (--timestamp). Sign deepest-first, app last.
step "Signing"
SIGN_IDENTITY="${OMI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"
[ -n "$SIGN_IDENTITY" ] || { echo "ERROR: no Developer ID Application identity found"; exit 1; }
echo "    identity: $SIGN_IDENTITY"
chmod -R u+w "$APP_BUNDLE"; xattr -cr "$APP_BUNDLE"
sign() { codesign --force --options runtime --timestamp "$@"; }

step "Signing nested Mach-O under Resources (node native modules, dylibs)"
while IFS= read -r -d '' f; do
  case "$f" in
    *.node|*.dylib|*.so) sign --sign "$SIGN_IDENTITY" "$f";;
    *) if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then sign --sign "$SIGN_IDENTITY" "$f"; fi;;
  esac
done < <(find "$APP_BUNDLE/Contents/Resources" -type f \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -perm +111 \) -print0)

# Bundled node runtime (JIT entitlements; re-sign over the generic pass above)
[ -f "$BUNDLED_NODE" ] && sign --entitlements Desktop/Node.entitlements --sign "$SIGN_IDENTITY" "$BUNDLED_NODE"

# Sparkle nested helpers, deepest first, then the framework
SPK_VER="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current"
for nested in "XPCServices/Downloader.xpc" "XPCServices/Installer.xpc" "Autoupdate" "Updater.app"; do
  [ -e "$SPK_VER/$nested" ] && sign --sign "$SIGN_IDENTITY" "$SPK_VER/$nested"
done

step "Signing frameworks + app"
for fw in Sparkle.framework Sentry.framework onnxruntime.framework; do
  [ -d "$APP_BUNDLE/Contents/Frameworks/$fw" ] && sign --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/$fw"
done
for lib in libsharpyuv.0.dylib libwebp.7.dylib; do
  [ -f "$APP_BUNDLE/Contents/Frameworks/$lib" ] && sign --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/$lib"
done
sign --entitlements Desktop/Omi-Release.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

# --- Notarize ---
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  step "SKIP_NOTARIZE=1 — skipping notarization (local smoke test only)"
else
  step "Notarizing (profile: $NOTARY_PROFILE)"
  mkdir -p "$DIST_DIR"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
fi

# --- Package (zip the stapled app) ---
step "Packaging $ZIP_PATH"
mkdir -p "$DIST_DIR"; rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
SHA256=$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)
echo "    sha256: $SHA256"

# --- Publish ---
if [ "${SKIP_PUBLISH:-0}" = "1" ]; then
  step "SKIP_PUBLISH=1 — built at $ZIP_PATH (sha256 $SHA256); not publishing"
  exit 0
fi
step "Publishing GitHub Release $TAG to $GH_REPO"
CHANGELOG_PY="../../.github/scripts/desktop-changelog.py"
RELEASE_NOTES="Fork desktop build $VERSION (signed + notarized, bundle $BUNDLE_ID)."
if UNRELEASED_MD="$(python3 "$CHANGELOG_PY" unreleased --format markdown 2>/dev/null)" \
  && [ -n "$UNRELEASED_MD" ]; then
  RELEASE_NOTES="$RELEASE_NOTES

## Changes
$UNRELEASED_MD"
fi
gh release create "$TAG" "$ZIP_PATH" --repo "$GH_REPO" --title "Omi desktop (fork) $VERSION" \
  --notes "$RELEASE_NOTES" || \
  gh release upload "$TAG" "$ZIP_PATH" --repo "$GH_REPO" --clobber
ASSET_URL="https://github.com/$GH_REPO/releases/download/$TAG/$(basename "$ZIP_PATH")"

step "Updating cask in $TAP_REPO"
CASK_TMP="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$CASK_TMP/tap" -- -q
mkdir -p "$CASK_TMP/tap/Casks"
cat > "$CASK_TMP/tap/Casks/omi.rb" <<CASK
cask "omi" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$ASSET_URL"
  name "Omi Dev"
  desc "Adam's Omi desktop fork (notarized)"
  homepage "https://github.com/$GH_REPO"

  app "$APP_NAME.app"
end
CASK
(cd "$CASK_TMP/tap" && git add Casks/omi.rb && git commit -q -m "omi $VERSION" && git push -q)
rm -rf "$CASK_TMP"

# --- Consolidate changelog fragments into a release entry ---
# Folds changelog/unreleased/*.json into changelog/releases/<version>.json and
# regenerates CHANGELOG.json, then lands it via a PR (never a direct push to
# main). Failures here warn instead of failing: the release itself is already
# published, and fragments simply stay pending for the next release.
consolidate_changelog() {
  if [ -z "$(ls changelog/unreleased/*.json 2>/dev/null)" ]; then
    echo "    no unreleased changelog fragments; skipping consolidation"
    return 0
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "    working tree is dirty; run the consolidation manually:"
    echo "    python3 $CHANGELOG_PY consolidate --version $VERSION --write"
    return 0
  fi
  local branch="chore/desktop-changelog-$VERSION"
  git checkout -q -b "$branch" \
    && python3 "$CHANGELOG_PY" consolidate --version "$VERSION" --write \
    && git add CHANGELOG.json changelog/ \
    && git commit -q -m "chore(desktop): consolidate changelog for fork release $VERSION" \
    && git push -q -u origin "$branch" \
    && gh pr create --repo "$GH_REPO" --base main --head "$branch" \
         --title "Consolidate desktop changelog for fork release $VERSION" \
         --body "Folds the unreleased changelog fragments shipped in $TAG into changelog/releases/$VERSION.json. Generated by release.sh." \
    && gh pr merge "$branch" --repo "$GH_REPO" --merge \
    && git checkout -q - \
    && git pull -q --ff-only
}
step "Consolidating changelog fragments for $VERSION"
consolidate_changelog || echo "    WARNING: changelog consolidation failed; fragments left in place"

TAP_SHORT="${TAP_REPO/\/homebrew-//}"  # adamlsneed/homebrew-omi -> adamlsneed/omi
step "Done. Install: brew install --cask $TAP_SHORT/omi   |   Update: brew upgrade"
