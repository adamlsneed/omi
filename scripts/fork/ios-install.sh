#!/usr/bin/env bash
# Build the Omi iOS app (prod flavor, Adam's local signing) from the checkout this
# script lives in and install it on Adam's iPhone. Guide: .github/agent-docs/ios-install.md
#
# Usage: scripts/fork/ios-install.sh [--device <id|name>] [--no-install]
# Exit codes: 0 installed and launched (or built with --no-install), 1 failure,
#             2 usage, 3 built but not installed (phone unreachable or locked),
#             4 installed but the Omi process is not running after launch.
set -euo pipefail

DEVICE="0AE733D7-AC04-58AB-B95A-B3D0486506F2"
INSTALL=1
CONFIG_DIR="${OMI_LOCAL_CONFIG:-$HOME/dev/omi-local-config}"
BUNDLE_ID="com.adam.omi.dev"
FIREBASE_PROJECT="based-hardware"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:?--device needs a value}"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# CocoaPods crashes under the harness's empty locale.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
APP="$ROOT/app"
DERIVED="$APP/build/ios-device"
BUILT_APP="$DERIVED/Build/Products/Release-prod-iphoneos/Runner.app"
LOG_DIR="$APP/build/ios-install-logs"
mkdir -p "$LOG_DIR"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# Run a noisy step with its output in $LOG_DIR/<name>.log; show the tail only on failure.
logged() {
  local name="$1"; shift
  if ! "$@" >"$LOG_DIR/$name.log" 2>&1; then
    tail -30 "$LOG_DIR/$name.log" >&2
    die "$name failed; full log: $LOG_DIR/$name.log"
  fi
}

step "Prerequisites ($ROOT)"
FLUTTER_PIN="$(grep -m1 -E '^\s*flutter-version:' "$ROOT/.github/workflows/mobile-app-checks.yml" | awk '{print $2}')"
[[ -n "$FLUTTER_PIN" ]] || die "could not read the pinned Flutter version from mobile-app-checks.yml"
FLUTTER_BIN="$HOME/fvm/versions/$FLUTTER_PIN/bin"
if [[ ! -x "$FLUTTER_BIN/flutter" ]]; then
  command -v fvm >/dev/null || die "Flutter $FLUTTER_PIN missing and fvm not installed (brew install fvm)"
  fvm install "$FLUTTER_PIN"
fi
export PATH="$FLUTTER_BIN:$FLUTTER_BIN/cache/dart-sdk/bin:$PATH"
echo "flutter: $FLUTTER_PIN ($FLUTTER_BIN)"
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild unavailable; install Xcode and run xcode-select -s /Applications/Xcode.app"
echo "xcode:   $(xcodebuild -version | head -1)"
command -v pod >/dev/null || die "CocoaPods not installed (brew install cocoapods)"
identity="$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' || true)"
[[ -n "$identity" ]] || die "no Apple Development signing identity in the keychain"
echo "signing: $identity"

step "Local config from $CONFIG_DIR"
[[ -d "$CONFIG_DIR/app" ]] || die "$CONFIG_DIR/app not found; see the recovery note in .github/agent-docs/ios-install.md"
# Always overwrite: gitignored config is per-worktree and a tree's own copies go stale.
while IFS= read -r rel; do
  if git -C "$ROOT" ls-files --error-unmatch "app/$rel" >/dev/null 2>&1; then
    continue  # tracked upstream file; never clobber it
  fi
  mkdir -p "$APP/$(dirname "$rel")"
  cp "$CONFIG_DIR/app/$rel" "$APP/$rel"
  echo "copied app/$rel"
done < <(cd "$CONFIG_DIR/app" && find . -type f ! -name .DS_Store | sed 's|^\./||')
# The Runner copy phase needs this input to exist before it runs.
cp "$APP/ios/Config/Prod/GoogleService-Info.plist" "$APP/ios/Runner/GoogleService-Info.plist"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
for plist in ios/Config/Prod/GoogleService-Info.plist ios/Runner/GoogleService-Info.plist; do
  [[ "$(plist_get PROJECT_ID "$APP/$plist")" == "$FIREBASE_PROJECT" ]] || die "$plist PROJECT_ID is not $FIREBASE_PROJECT"
  [[ "$(plist_get BUNDLE_ID "$APP/$plist")" == "$BUNDLE_ID" ]] || die "$plist BUNDLE_ID is not $BUNDLE_ID"
done
ios_opts="$(awk '/static const FirebaseOptions ios/,/\);/' "$APP/lib/firebase_options_prod.dart")"
grep -q "projectId: '$FIREBASE_PROJECT'" <<<"$ios_opts" \
  || die "lib/firebase_options_prod.dart ios projectId is not $FIREBASE_PROJECT (app would show 'Omi could not start')"
grep -q "iosBundleId: '$BUNDLE_ID'" <<<"$ios_opts" || die "lib/firebase_options_prod.dart iosBundleId is not $BUNDLE_ID"
grep -q "APP_BUNDLE_IDENTIFIER=$BUNDLE_ID" "$APP/ios/Flutter/LocalSigning.xcconfig" \
  || die "LocalSigning.xcconfig does not set APP_BUNDLE_IDENTIFIER=$BUNDLE_ID"
echo "firebase: $FIREBASE_PROJECT, bundle $BUNDLE_ID"

cd "$APP"
step "flutter pub get + env codegen"
logged pub-get flutter pub get
# Full build: a --build-filter run deletes tracked outputs outside the filter.
logged build-runner dart run build_runner build --delete-conflicting-outputs

step "CocoaPods"
# Retry with a spec-repo refresh; the CDN fails transiently.
pod_install() ( cd ios && { pod install || pod install --repo-update; } )
if cmp -s ios/Podfile.lock ios/Pods/Manifest.lock; then
  echo "Pods up to date, skipping pod install"
else
  logged pod-install pod_install
fi

step "flutter build ios (prod, config-only)"
logged flutter-config flutter build ios --release --flavor prod --config-only --no-codesign

step "xcodebuild (Release-prod, generic iOS, LocalSigning)"
start=$SECONDS
if ! xcodebuild -workspace ios/Runner.xcworkspace -scheme prod -configuration Release-prod \
  -destination 'generic/platform=iOS' \
  -xcconfig ios/Flutter/LocalSigning.xcconfig \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build >"$LOG_DIR/xcodebuild.log" 2>&1; then
  grep -E 'error:|BUILD FAILED' "$LOG_DIR/xcodebuild.log" | tail -20 >&2
  if grep -q 'No Accounts' "$LOG_DIR/xcodebuild.log"; then
    echo "Xcode has no Apple ID (fresh Xcode install?). Adam must add it: Xcode > Settings > Accounts." >&2
  fi
  die "xcodebuild failed; full log: $LOG_DIR/xcodebuild.log"
fi
echo "xcodebuild done in $((SECONDS - start))s"

[[ "$(plist_get CFBundleIdentifier "$BUILT_APP/Info.plist")" == "$BUNDLE_ID" ]] || die "built app bundle id is not $BUNDLE_ID"
[[ "$(plist_get PROJECT_ID "$BUILT_APP/GoogleService-Info.plist")" == "$FIREBASE_PROJECT" ]] \
  || die "built app GoogleService-Info.plist is not $FIREBASE_PROJECT"
version="$(plist_get CFBundleShortVersionString "$BUILT_APP/Info.plist") ($(plist_get CFBundleVersion "$BUILT_APP/Info.plist"))"
echo "built $version: $BUILT_APP"

if [[ $INSTALL -eq 0 ]]; then
  echo "built, not installed (--no-install): $BUILT_APP"
  exit 0
fi

step "Install on $DEVICE"
# The watch app is embedded in Runner.app, so this also updates the paired Apple Watch.
if ! xcrun devicectl device install app --timeout 300 --device "$DEVICE" "$BUILT_APP"; then
  echo
  echo "built, not installed: $BUILT_APP"
  echo "The phone is unreachable or locked. Unlock it, keep it awake, and rerun, or install directly:"
  echo "  xcrun devicectl device install app --device $DEVICE '$BUILT_APP'"
  exit 3
fi

if ! xcrun devicectl device process launch --timeout 60 --device "$DEVICE" --terminate-existing "$BUNDLE_ID"; then
  echo "installed $version, but launch failed (phone locked?)"
  exit 4
fi

step "Verify"
apps_json="$LOG_DIR/device-apps.json"
xcrun devicectl device info apps --device "$DEVICE" --bundle-id "$BUNDLE_ID" --quiet --json-output "$apps_json"
installed_version="$(plutil -extract result.apps.0.version raw "$apps_json") ($(plutil -extract result.apps.0.bundleVersion raw "$apps_json"))"
app_url="$(plutil -extract result.apps.0.url raw "$apps_json")"
# Match the new install container so a stale Runner from an older install does not count.
runner_path="${app_url#file://}Runner"
sleep 6
processes="$(xcrun devicectl device info processes --device "$DEVICE")"
if ! grep -qF "$runner_path" <<<"$processes"; then
  echo "installed $installed_version, but no Omi process is running (crashed at startup?): $runner_path"
  exit 4
fi
echo "installed $installed_version, Omi process running"
echo "done in $((SECONDS / 60))m$((SECONDS % 60))s"
