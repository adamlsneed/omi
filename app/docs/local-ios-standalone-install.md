# Local iOS Standalone Install Notes

These notes document the local Adam iPhone install path and the failure modes
we hit while replacing the installed Omi Dev app. Keep this file focused on
local device deployment; production/TestFlight/App Store signing is separate.

## Known Local Identity

- App name: `Omi Dev`
- Local bundle id: `com.adam.omi.dev`
- Local app group: `group.com.adam.omi.dev`
- Apple Development certificate: `Apple Development: coralcaves@gmail.com (M6V8W4X24Z)`
- Xcode development team: `66K48S8RD4`
- Xcode destination device id: `00008150-001004D93E40401C`
- `devicectl` device id: `0AE733D7-AC04-58AB-B95A-B3D0486506F2`
- Hosted backend/auth must remain in use for Adam's active testing:
  `API_BASE_URL=https://api.omi.me/`, `USE_WEB_AUTH=true`,
  `USE_AUTH_CUSTOM_TOKEN=true`
- Adam's active local phone app should use the prod Firebase flavor with local
  signing. The local bundle id remains `com.adam.omi.dev`, but Google auth
  custom tokens from `https://api.omi.me/` are for the prod Firebase project
  (`based-hardware`), not the dev Firebase project (`based-hardware-dev`).

## What Went Wrong

### Debug build installed as a standalone app

Symptom:

```text
Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode.
Flutter application in debug mode can only be launched from Flutter tooling, use profile or release modes instead.
```

Root cause: a `Debug-dev` Flutter iOS build was installed onto the phone and
then launched from the home screen/device services without Flutter tooling
attached. That is expected to terminate. It is not evidence that the app logic
itself is crashing.

Fix: install a Profile or Release build for standalone use. For Adam's active
hosted-backend phone app, use `Profile-dev` or `Release-dev` (the **dev flavor**,
with its Firebase config repointed at the `based-hardware` project — see the
custom-token-mismatch section below) plus the local signing override. Do not use
the prod flavor locally.

### Hosted Google/Apple auth fails after returning to the app (custom-token-mismatch)

Symptom: the app launches and you can complete the hosted Google/Apple browser
flow, but sign-in fails the instant it redirects back into the app
(`omi://auth/callback`). The on-screen message is generic ("Failed to sign in").
With on-device file logging enabled (see "Capturing the real auth error" below),
the exact error is:

```text
[firebase_auth/custom-token-mismatch] The custom token corresponds to a different audience.
```

Root cause — **Firebase project mismatch** (this is the #1 gotcha; it cost ~2h once):
a locally signed build initializes the **dev** Firebase project
(`based-hardware-dev`, project number `1031333818730`). The hosted backend at
`https://api.omi.me/` mints a Firebase **custom token** signed by a service
account in the **prod project `based-hardware`** (project number `208440318997`,
issuer `...@based-hardware.iam.gserviceaccount.com`). `signInWithCustomToken`
only accepts a token whose project matches the app's Firebase project, so they
must match. Note the token exchange itself **succeeds** (HTTP 200 from
`/v1/auth/token`, returns a `custom_token`) because the backend is bundle-id
agnostic — only the final client-side sign-in fails. So a 200 on the exchange
plus a sign-in failure = project mismatch, not a backend/redirect problem.

Two facts that made this confusing and are easy to get wrong:

- The prod Firebase project is named **`based-hardware`** (bare), NOT
  `based-hardware-prod`. Older docs said `based-hardware-prod` — that project
  does not exist.
- On this machine **every** Firebase config (dev flavor, prod flavor, iOS and
  Android) was pointed at `based-hardware-dev`. None matched the hosted backend.

Fix: build the **dev flavor** (its `.dev.env` carries the working hosted config —
`API_BASE_URL=https://api.omi.me/`, `USE_WEB_AUTH=true`,
`USE_AUTH_CUSTOM_TOKEN=true`) but point its Firebase config at the **prod
`based-hardware`** project. Build commands are in the next section. The
`based-hardware` client config (API key, app id, sender id, storage bucket) is
available locally in `desktop/macos/Desktop/Sources/GoogleService-Info.plist`
(PROJECT_ID `based-hardware`, sender `208440318997`) — copy those values into:

- `app/lib/firebase_options_dev.dart` — the `ios` `FirebaseOptions` (apiKey,
  appId, messagingSenderId, projectId, storageBucket, iosClientId), with
  `iosBundleId: 'com.adam.omi.dev'`. This is what `Firebase.initializeApp` uses.
- `app/ios/Config/Dev/GoogleService-Info.plist` and
  `app/ios/Runner/GoogleService-Info.plist` — copy the desktop plist over each
  and set `BUNDLE_ID` to `com.adam.omi.dev`.

Do **not** build the **prod flavor** for the hosted build. Locally `.prod.env` is
missing, so the prod env codegen falls back to defaults (`apiBaseUrl=null`,
`useWebAuth=false`); that build (a) can't reach any backend and (b) takes the
**native** Google Sign-In path, which crashes on the re-bundled
`com.adam.omi.dev` (its OAuth client / URL scheme is registered only for the
official bundle). The prod flavor's widget App Group signing also fails locally
(see next section). Web auth (`USE_WEB_AUTH=true`, dev flavor) avoids the native
crash entirely.

### Local dev shell with prod Firebase auth

On Adam's Mac, the local Apple account currently has valid explicit
provisioning profiles for the dev shell:

- app: `com.adam.omi.dev`
- widget: `com.adam.omi.dev.development.widget`
- app group: `group.com.adam.omi.dev`

The prod flavor uses the widget bundle id `com.adam.omi.dev.widget`, which may
fail to sign until Apple Developer has an explicit App ID/profile for that
extension and the `group.com.adam.omi.dev` App Group. The failure looks like:

```text
Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the App Groups capability.
Provisioning profile "iOS Team Provisioning Profile: *" doesn't support the group.com.adam.omi.dev App Group.
```

When that happens, build the signable `Release-dev` shell but restore the local
ignored dev Firebase inputs to the prod Firebase project (`based-hardware`).
This keeps the installed app as `Omi Dev`, reuses the working local profiles,
and still matches hosted backend custom-token auth from `https://api.omi.me/`.

Before building, verify:

```bash
/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' ios/Config/Dev/GoogleService-Info.plist
rg -n "projectId: 'based-hardware'" lib/firebase_options_dev.dart
```

Expected:

```text
based-hardware
```

Then build and install:

```bash
flutter build ios --release --flavor dev --config-only --no-codesign

xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme dev \
  -configuration Release-dev \
  -destination 'id=00008150-001004D93E40401C' \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

This is a local-install workaround, not an upstream release configuration. Do
not commit the ignored Firebase config files.

### Capturing the real auth error (on-device file log)

When sign-in (or anything else) fails on a **Profile/Release** build, the
on-screen message is generic and **Dart `print`/`Logger` output is not
retrievable by the usual tools** — all of these were tried and only surface
native (Swift/Firebase) os_log, never Dart logs:

- `idevicesyslog` — native only
- `xcrun devicectl device process launch --console` — native only
- `flutter attach` — "connection to device ended too early"
- `flutter run --debug` — the Dart VM Service never gets discovered over USB on
  this device (10-min timeout, "Error running application")

What works: the app's own file logger, `DebugLogManager`
(`app/lib/utils/debug_log_manager.dart`). It writes JSON lines to
`Documents/omi_debug_YYYYMMDD.log` (UTC), but only when `devLogsToFileEnabled`
is on — and that toggle lives in **Developer settings, behind the sign-in wall**.
For a dev-signed app you can flip it without the UI by editing the container's
prefs plist, then pull the log via `devicectl`:

```bash
DEV=0AE733D7-AC04-58AB-B95A-B3D0486506F2   # devicectl id (Xcode id: 00008150-001004D93E40401C)

# 1) enable file logging
xcrun devicectl device copy from --device $DEV --domain-type appDataContainer \
  --domain-identifier com.adam.omi.dev \
  --source Library/Preferences/com.adam.omi.dev.plist --destination /tmp/p.plist
/usr/libexec/PlistBuddy -c "Add :flutter.devLogsToFileEnabled bool true" /tmp/p.plist
xcrun devicectl device copy to --device $DEV --domain-type appDataContainer \
  --domain-identifier com.adam.omi.dev \
  --source /tmp/p.plist --destination Library/Preferences/com.adam.omi.dev.plist

# 2) relaunch app (must be unlocked), reproduce the failure, then pull the log
xcrun devicectl device copy from --device $DEV --domain-type appDataContainer \
  --domain-identifier com.adam.omi.dev \
  --source Documents/omi_debug_$(date -u +%Y%m%d).log --destination /tmp/omi_debug.log

# 3) when done: set the flag back to false (it can log tokens) and clear the file
```

Gotchas:

- `DebugLogManager.logError(error, stack, message)` records `message ?? error.toString()`,
  so a call that passes a fixed `message` (e.g. `Logger.handle(e, st, message: 'Authentication failed')`)
  **hides the actual exception**. To capture it, temporarily change the message to
  include `$e` (revert after).
- The auth flow logs the `/v1/auth/token` response (including `id_token`,
  `access_token`, `custom_token`) — these are sensitive. The `custom_token` is a
  JWT whose `iss` names the Firebase project; decode it to confirm which project
  the backend is minting for. **Clear the device log and any local copies, and
  set `devLogsToFileEnabled` back to false, when finished.**
- devicectl container access (`copy from`/`copy to --domain-type appDataContainer`)
  works because the app is dev-signed. `process launch` requires the device
  unlocked. Installing over the same bundle id is an in-place upgrade (preserves
  data; `SharedPreferences` + Firebase keychain persist across reinstalls).

### Capturing Dart logs another way — flutter run signing

`flutter run` (which would stream Dart logs) can't be pointed at a custom
`-xcconfig`, and the pbxproj hard-codes `DEVELOPMENT_TEAM = 9536L8KLMP`
(BasedHardware), so it won't sign for Adam's team. To make `flutter run` work you
must temporarily (a) `sed` the team to `66K48S8RD4` in
`app/ios/Runner.xcodeproj/project.pbxproj` and (b) append
`#include "LocalSigning.xcconfig"` to `app/ios/Flutter/devDebug.xcconfig`, then
revert both. For everything except live Dart logs, prefer the signed
`xcodebuild -xcconfig ios/Flutter/LocalSigning.xcconfig` path (no project edits).

### Two Omi Dev entries or stale Runner processes

Symptom: after replacing the app, device process listings can show more than
one `Runner` process, sometimes from an older bundle container path.

Root cause: iOS can keep or briefly resurrect a stale process from a previous
install container. Treat the installed-app list as the source of truth for
whether multiple apps are actually installed.

Checks:

```bash
xcrun devicectl device info apps \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 | rg -i 'Omi|com\.adam\.omi'

xcrun devicectl device info processes \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 | rg -i 'omi|runner|com\.adam\.omi'
```

If the app list shows only `Omi Dev com.adam.omi.dev`, there is only one
installed local Omi app. If process listing shows an extra stale `Runner`, kill
that PID and recheck:

```bash
xcrun devicectl device process terminate \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 \
  --pid <stale-runner-pid> \
  --kill
```

### Missing ignored local inputs in a fresh worktree

Symptom: Flutter/Xcode build fails because Firebase config, `.dev.env`, or local
signing overrides are missing.

Root cause: those files are intentionally ignored and must be copied into fresh
worktrees before local device builds.

Required local inputs:

- `.dev.env`
- `.env`
- `lib/firebase_options_dev.dart`
- `lib/firebase_options_prod.dart`
- `ios/Config/Dev/GoogleService-Info.plist`
- `ios/Config/Prod/GoogleService-Info.plist`
- `ios/Config/Dev/GoogleService-Info.plist` and `ios/Runner/GoogleService-Info.plist`
  must hold the **`based-hardware`** project config (PROJECT_ID `based-hardware`),
  not `based-hardware-dev` — source the values from
  `desktop/macos/Desktop/Sources/GoogleService-Info.plist` and set `BUNDLE_ID` to
  `com.adam.omi.dev`. Likewise `lib/firebase_options_dev.dart` (ios block).
- `ios/Flutter/LocalSigning.xcconfig` copied from
  `ios/Flutter/LocalSigning.example.xcconfig`

Do not run `flutterfire configure`; it can overwrite official config files.

### Stale ignored env codegen

Symptom:

```text
lib/env/dev_env.dart: Error: Member not found: 'posthogApiKey'.
lib/env/prod_env.dart: Error: Member not found: 'posthogApiKey'.
```

Root cause: `lib/env/dev_env.g.dart` and `lib/env/prod_env.g.dart` are ignored
generated files. A fresh worktree can inherit old generated env code that no
longer matches the checked-in `dev_env.dart` and `prod_env.dart` interfaces.

Fix: restore both `.dev.env` and `.env`, then regenerate before building:

```bash
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
```

### Launch verification ambiguity

`devicectl process launch --console --timeout ...` is useful for catching an
immediate crash, but a timeout can be ambiguous because a healthy app keeps
running. Prefer this sequence:

```bash
xcrun devicectl device process launch \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 \
  --terminate-existing \
  com.adam.omi.dev

sleep 6

xcrun devicectl device info processes \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 | rg -i 'omi|runner|com\.adam\.omi'
```

Use `--console` afterward only if the app vanishes and the launch crash output is
needed.

## Safe Build And Replace Procedure

From `app/` in the active checkout:

```bash
flutter pub get
# Do NOT run `build_runner build --delete-conflicting-outputs` unless BOTH .dev.env
# and .prod.env exist — without them envied silently defaults secrets (apiBaseUrl=null,
# useWebAuth=false), which is what breaks auth. The committed *_env.g.dart hold valid
# dev values; leave them.
flutter build ios --profile --flavor dev --config-only --no-codesign

# Prereq (one-time, see custom-token-mismatch section above): firebase_options_dev.dart
# (ios block) + ios/Config/Dev/GoogleService-Info.plist + ios/Runner/GoogleService-Info.plist
# must already be repointed at the `based-hardware` project, not based-hardware-dev.
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme dev \
  -configuration Profile-dev \
  -destination 'id=00008150-001004D93E40401C' \
  -xcconfig ios/Flutter/LocalSigning.xcconfig \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

Before installing, verify the built app identity and entitlements:

```bash
APP=~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Profile-dev-iphoneos/Runner.app
ENT=/tmp/omi-profile-entitlements.plist

/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :OmiAppGroupIdentifier' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$APP/GoogleService-Info.plist"
codesign -d --entitlements :- "$APP" > "$ENT" 2>/tmp/omi-profile-codesign-err
/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$ENT"
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$ENT"
/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.healthkit' "$ENT"
```

Expected values:

- `CFBundleIdentifier`: `com.adam.omi.dev`
- display name: `Omi Dev`
- `OmiAppGroupIdentifier`: `group.com.adam.omi.dev`
- `PROJECT_ID`: `based-hardware`
- `application-identifier`: `66K48S8RD4.com.adam.omi.dev`
- application groups includes `group.com.adam.omi.dev`
- HealthKit entitlement is `true`

Install over the existing local app:

```bash
xcrun devicectl device install app \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 \
  "$APP"
```

Prefer installing over the existing app to preserve local app data. Uninstall
only if installation fails or if the user explicitly accepts data loss.

Launch and verify:

```bash
xcrun devicectl device process launch \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 \
  --terminate-existing \
  com.adam.omi.dev

sleep 6

xcrun devicectl device info apps \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 | rg -i 'Omi|com\.adam\.omi'

xcrun devicectl device info processes \
  --device 0AE733D7-AC04-58AB-B95A-B3D0486506F2 | rg -i 'omi|runner|com\.adam\.omi'
```

## Verification Checklist

- `flutter build ios --profile --flavor dev --config-only --no-codesign`
  completes successfully.
- `xcodebuild ... -scheme dev -configuration Profile-dev -xcconfig ios/Flutter/LocalSigning.xcconfig ... build` exits 0.
- The dev flavor's Firebase config is repointed at `based-hardware` (do not use the
  prod flavor locally — `.prod.env` is absent and its widget App Group won't sign).
- Entitlements match the expected local bundle id, app group, and HealthKit
  values before installation, and `GoogleService-Info.plist` reports
  `PROJECT_ID=based-hardware`.
- `devicectl device install app` reports `bundleID: com.adam.omi.dev`.
- `devicectl device info apps` shows only one local Omi app unless the user has
  intentionally installed another bundle id.
- `devicectl device info processes` shows one current `Runner` process after any
  stale old-container process is terminated.
- `bash app/test.sh` passes before committing doc or app changes.
