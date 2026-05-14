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
hosted-backend phone app, use `Profile-prod` or `Release-prod` with the local
signing override.

### Hosted Google auth with the wrong Firebase flavor

Symptom: the app launches, but Google sign-in fails after the hosted browser
flow or after returning to the app.

Root cause: a locally signed `Profile-dev` build initializes the dev Firebase
project (`based-hardware-dev`). The hosted backend at `https://api.omi.me/`
uses the prod Google/Firebase auth path and returns tokens for the prod Firebase
project (`based-hardware`). Those pieces must match.

Fix: keep the local bundle id/app group override, but build Adam's active phone
app with the prod flavor:

```bash
flutter build ios --profile --flavor prod --config-only --no-codesign

xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme prod \
  -configuration Profile-prod \
  -destination 'id=00008150-001004D93E40401C' \
  -xcconfig ios/Flutter/LocalSigning.xcconfig \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

Use `Profile-dev` only when intentionally testing the dev Firebase/backend
environment.

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
- `ios/Runner/GoogleService-Info.plist` copied from the prod plist before first
  build for Adam's hosted-backend phone app
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
flutter pub run build_runner build --delete-conflicting-outputs
flutter build ios --profile --flavor prod --config-only --no-codesign

xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme prod \
  -configuration Profile-prod \
  -destination 'id=00008150-001004D93E40401C' \
  -xcconfig ios/Flutter/LocalSigning.xcconfig \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

Before installing, verify the built app identity and entitlements:

```bash
APP=~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Profile-prod-iphoneos/Runner.app
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

- `flutter build ios --profile --flavor prod --config-only --no-codesign`
  completes successfully.
- `xcodebuild ... -configuration Profile-prod ... build` exits 0.
- Entitlements match the expected local bundle id, app group, and HealthKit
  values before installation, and `GoogleService-Info.plist` reports
  `PROJECT_ID=based-hardware`.
- `devicectl device install app` reports `bundleID: com.adam.omi.dev`.
- `devicectl device info apps` shows only one local Omi app unless the user has
  intentionally installed another bundle id.
- `devicectl device info processes` shows one current `Runner` process after any
  stale old-container process is terminated.
- `bash app/test.sh` passes before committing doc or app changes.
