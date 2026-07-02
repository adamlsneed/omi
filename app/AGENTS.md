# App (Flutter) — Operational Playbook

Inherits all rules from the root [`../AGENTS.md`](../AGENTS.md). This file adds app-specific operational guidance.

## Build Bootstrap

### Flavors
- **dev**: `com.friend.ios.dev` — uses `.dev.env`, Firebase project `based-hardware-dev`
- **prod**: `com.friend.ios` — uses `.prod.env`, Firebase project **`based-hardware`** (bare name — there is no `based-hardware-prod` project; `api.omi.me` hosted auth mints custom tokens for `based-hardware`)

### Generated Files (never edit manually)
| Generator | Source | Output | Command |
|-----------|--------|--------|---------|
| envied | `lib/env/dev_env.dart`, `lib/env/prod_env.dart` | `*.g.dart` (obfuscated secrets) | `flutter pub run build_runner build` |
| json_serializable | `@JsonSerializable` models | `*.g.dart` (fromJson/toJson) | `flutter pub run build_runner build` |
| pigeon | `lib/watch_interface.dart` | `lib/gen/flutter_communicator.g.dart` + iOS/Android stubs | `flutter pub run build_runner build` |
| flutter_gen | `pubspec.yaml` assets/fonts | `lib/gen/assets.gen.dart`, `lib/gen/fonts.gen.dart` | `flutter pub run build_runner build` |
| flutter_localizations | `lib/l10n/*.arb` | `lib/gen_l10n/app_localizations*.dart` | `flutter gen-l10n` |

### Setup Sequence
```bash
bash setup.sh ios    # or: bash setup.sh android
```
This handles: pub get, build_runner, gen-l10n, and flavor configuration.

### Adam Local iPhone Signing
- The local Apple Development cert is displayed as `Apple Development: coralcaves@gmail.com (M6V8W4X24Z)`, but the usable Xcode team identifier is `66K48S8RD4`.
- For physical-device installs on Adam's iPhone, copy `ios/Flutter/LocalSigning.example.xcconfig` to ignored `ios/Flutter/LocalSigning.xcconfig` and build with `-xcconfig ios/Flutter/LocalSigning.xcconfig -allowProvisioningUpdates -allowProvisioningDeviceRegistration`.
- Keep hosted backend auth in `.env` and `.dev.env`: `API_BASE_URL=https://api.omi.me/`, `USE_WEB_AUTH=true`, `USE_AUTH_CUSTOM_TOKEN=true`.
- **Hosted-backend phone build = dev flavor + `based-hardware` Firebase (NOT the prod flavor).** Build the **dev** flavor (`com.adam.omi.dev` via LocalSigning) because its `.dev.env` has the working hosted config (`API_BASE_URL=https://api.omi.me/`, `USE_WEB_AUTH=true`, `USE_AUTH_CUSTOM_TOKEN=true`), but **repoint the dev flavor's Firebase config at the prod `based-hardware` project** (NOT `based-hardware-dev`). Do NOT build the **prod flavor** locally: `.prod.env` is missing (→ `apiBaseUrl=null`, and `useWebAuth=false` so it takes the native Google Sign-In path that crashes on the re-bundled id), and the prod widget App Group won't sign. If sign-in fails right after the browser redirect with `[firebase_auth/custom-token-mismatch] The custom token corresponds to a different audience.`, the app's Firebase project does not match `based-hardware`. The `based-hardware` client config is in `desktop/macos/Desktop/Sources/GoogleService-Info.plist`. Full writeup + the on-device log-capture recipe: `docs/local-ios-standalone-install.md`.
- In fresh worktrees, restore ignored local inputs before building: `.dev.env`, `.env`, `lib/firebase_options_dev.dart`, `lib/firebase_options_prod.dart`, `ios/Config/{Dev,Prod}/GoogleService-Info.plist`. For Adam's hosted build, the dev-flavor Firebase inputs (`lib/firebase_options_dev.dart` ios block, `ios/Config/Dev/GoogleService-Info.plist`, `ios/Runner/GoogleService-Info.plist`) must be the **`based-hardware`** project config (source: `desktop/macos/Desktop/Sources/GoogleService-Info.plist`, `BUNDLE_ID=com.adam.omi.dev`) — not `based-hardware-dev`.
- Always refresh paths in the active checkout before local device builds: `flutter pub get`, then `flutter build ios --profile --flavor dev --config-only --no-codesign`. Do NOT run `build_runner build --delete-conflicting-outputs` unless both `.dev.env` and `.prod.env` are present — regenerating env codegen without them silently defaults secrets (`apiBaseUrl=null`, `useWebAuth=false`), which is exactly what leaves the prod flavor broken. The committed `*_env.g.dart` already hold valid dev values; leave them.
- For standalone iPhone installs, build `Profile-dev` or `Release-dev` (dev flavor with Firebase repointed at `based-hardware`) for Adam's active hosted-backend app; never install a `Debug-dev` build for normal home-screen use because Flutter debug iOS apps require Flutter tooling or Xcode to be attached and will terminate on launch.
- Adam's known device IDs: Xcode destination `00008150-001004D93E40401C`; `devicectl` device `0AE733D7-AC04-58AB-B95A-B3D0486506F2`.
- Local signing installs bundle `com.adam.omi.dev`. Replacing the official Omi bundle requires valid BasedHardware signing assets.
- Do not commit generated `LocalSigning.xcconfig` files or provisioning profiles. The committed example intentionally documents Adam's default local bundle/app group; override only in the ignored local xcconfig if a future install needs different IDs.
- Before replacing Adam's installed iPhone app, review `docs/local-ios-standalone-install.md`. It records the `Debug-dev` standalone crash, stale `Runner` process cleanup, entitlement checks, and hosted-backend/local-signing requirements from the May 2026 install issue.

### Firebase Config
Never run `flutterfire configure` — it overwrites prod credentials. Config files:
- Dev: `ios/Config/Dev/`, `android/app/src/dev/`, `lib/firebase_options_dev.dart`
- Prod: `ios/Config/Prod/`, `android/app/src/prod/`, `lib/firebase_options_prod.dart`

## Native Bridge

### Pigeon Interface (bidirectional, iOS ↔ Dart)
- Contract: `lib/watch_interface.dart` — 13 methods (recording, audio, battery, permissions)
- Dart side: `lib/gen/flutter_communicator.g.dart`
- iOS side: `ios/Runner/FlutterCommunicator.g.swift`
- Implementation: `ios/Runner/RecorderHostApiImpl.swift`
- After editing `watch_interface.dart`, regenerate: `flutter pub run build_runner build`

### MethodChannel (Phone Calls)
- Channel: `com.omi/phone_calls` + EventChannel `com.omi/phone_calls/events`
- Dart: `lib/services/phone_call_service.dart`
- iOS: `ios/Runner/PhoneCallsPlugin.swift`
- Methods: initialize, makeCall, endCall, toggleMute, toggleSpeaker

## Permission Matrix

| Permission | Android | iOS | Feature |
|-----------|---------|-----|---------|
| Microphone | RECORD_AUDIO | NSMicrophoneUsageDescription | Recording, speech profile |
| Bluetooth | BLUETOOTH_SCAN, BLUETOOTH_CONNECT | NSBluetoothAlwaysUsageDescription | Omi device connection |
| Location | ACCESS_FINE_LOCATION | NSLocationUsageDescription | Background features |
| Contacts | READ_CONTACTS | NSContactsUsageDescription | People recognition |
| Calendar | READ/WRITE_CALENDAR | NSCalendarsUsageDescription | Calendar integration |
| Camera | — | NSCameraUsageDescription | QR/photo features |
| Notifications | POST_NOTIFICATIONS | (automatic) | Push notifications |
| Background | FOREGROUND_SERVICE_* (4 types) | UIBackgroundModes (7 modes) | Continuous capture |

Android has 26 total permissions in AndroidManifest.xml. iOS has 11 background modes + 10 consent strings.

## Test Strategy

### Test Structure
- `test/unit/` — Auth, tokens, preferences, audio utils
- `test/widgets/` — UI components (shimmer, waveform, transcript)
- `test/providers/` — State management (capture_provider, device_provider)
- `test/utils/` — Utility functions (localization helpers)

### Running Tests
```bash
bash test.sh           # runs all tests
flutter test           # same thing
flutter test test/unit/  # specific directory
```

`bash test.sh` bootstraps missing local generated files with an empty `API_BASE_URL`.
Set `OMI_APP_TEST_API_BASE_URL=http://127.0.0.1:<port>/` for local backend tests, or
`OMI_APP_TEST_USE_PROD_API_DEFAULT=1` only when a test intentionally needs the prod API default.

### Test Patterns
- Mock singletons (SharedPreferencesUtil, AuthService, FirebaseAuth) since they aren't injectable
- Test state machine logic via minimal abstractions mirroring production flow
- No integration tests currently (integration_test dependency exists but unused)

## Localization (l10n)

- All user-facing strings must use `context.l10n.keyName`
- 49 locales: English (template) + 48 translations in `lib/l10n/`. Don't trust this count from memory — enumerate with `ls lib/l10n/app_*.arb`.
- Template: `lib/l10n/app_en.arb`
- Add keys via `jq` (never read full ARB — they're large). Use skill `add-a-new-localization-key-l10n-arb`
- Translate all locales — use skill `omi-add-missing-language-keys-l10n` for real translations
- Regenerate after changes: `flutter gen-l10n`. Task is only complete when this command emits zero "untranslated message(s)" warnings. To get the exact missing-key list, temporarily add `untranslated-messages-file: /tmp/untranslated.json` to `l10n.yaml` and re-run.

## Auth & Security

### Token Lifecycle
1. `getAuthHeader()` in `lib/backend/http/shared.dart` checks token expiry (5-minute buffer)
2. If expired, calls `AuthService.instance.getIdToken()` for Firebase refresh
3. Token stored in SharedPreferencesUtil with expiration timestamp
4. 401 responses trigger automatic refresh + retry

### Auth Methods
- Google Sign In (`google_sign_in` package)
- Apple Sign In (`sign_in_with_apple` package, includes PKCE via nonce+sha256)
- Firebase Auth as the identity layer

### Request Headers
All API requests include: X-Request-Start-Time, X-App-Platform, X-Device-Id-Hash, X-App-Version, plus Bearer token.

### API Base URLs
- Dev: configured in `.dev.env` → `Env.apiBaseUrl`
- Prod: configured in `.prod.env` → `Env.apiBaseUrl`
- Agent proxy WS: derived from apiBaseUrl (api.omi.me → agent.omi.me)

## Codegen Rules

- Run `flutter pub run build_runner build` after changing: env files, model annotations, pigeon contracts, or pubspec assets
- Run `flutter gen-l10n` after changing ARB files
- Never edit files ending in `.g.dart` or `.gen.dart`
- If build_runner fails with conflicts: `flutter pub run build_runner build --delete-conflicting-outputs`

## App Flows & E2E

- See `e2e/SKILL.md` for navigation architecture, screen map, widget patterns, and 34 reference flows
- See `e2e/flows/*.yaml` for individual flow definitions
- agent-flutter (Marionette) for programmatic UI interaction — see root AGENTS.md for setup
