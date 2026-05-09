# iOS Development Notes

Last updated: 2026-05-08

This document records the current local iOS state, the fixes made in this fork, and the plan for moving toward a ScoutPulse/NarraMind build while continuing to use Omi's hosted backend during development.

## Current Goals

- Keep using Omi's hosted backend because the developer account has an active paid Omi subscription.
- Keep local iOS builds working on Adam's iPhone without committing user-specific secrets, private API URLs, or local signing changes.
- Keep pulling upstream BasedHardware/Omi changes into this fork, compare conflicts, preserve local fixes, and push only to `origin` (`adamlsneed/omi`), never upstream.
- Move toward a ScoutPulse-owned product identity, likely `NarraMind` with bundle IDs under `com.scoutpulse.narramind`, after the signing, Firebase, and backend-token implications are explicit.

## Current iOS App State

The app is still the Flutter Omi mobile app under `app/`, with iOS native code in `app/ios/Runner/`.

### Flavors And Bundle IDs

- Dev flavor: `com.friend-app-with-wearable.ios12.development`
- Prod flavor: `com.friend-app-with-wearable.ios12`
- Dev display name: `Omi Dev`
- Prod display name: `Omi`
- Current committed Xcode team remains the upstream team ID in the project file. Local deploys may temporarily override the team to Adam's Apple team, but those changes are local-only and must not be committed until the ScoutPulse identifiers/profiles are ready.

### Backend And Auth

For the paid Omi subscription path, local/dev builds should use:

```env
API_BASE_URL=https://api.omi.me/
USE_WEB_AUTH=true
USE_AUTH_CUSTOM_TOKEN=true
```

The hosted auth flow is:

1. The app opens Omi hosted browser auth through `AuthService.authenticateWithProvider(...)`.
2. The browser goes to `https://api.omi.me/v1/auth/authorize`.
3. The callback returns to `omi://auth/callback`.
4. The app exchanges the authorization code at `https://api.omi.me/v1/auth/token`.
5. With `USE_AUTH_CUSTOM_TOKEN=true`, the app signs in with `FirebaseAuth.instance.signInWithCustomToken(...)`.

Important guardrail: Firebase custom tokens are tied to the Firebase project that minted them. If the app uses `api.omi.me`, the app-side Firebase configuration must be compatible with the Omi backend token issuer. Do not switch a hosted-backend build to a ScoutPulse/NarraMind Firebase project until the hosted backend can issue custom tokens for that Firebase project. Otherwise Google browser auth can succeed and the app can still fail immediately after redirecting back.

### Firebase Config

Tracked source uses ignored/generated Firebase files:

- `app/lib/firebase_options_dev.dart`
- `app/lib/firebase_options_prod.dart`
- `app/ios/Config/Dev/GoogleService-Info.plist`
- `app/ios/Config/Prod/GoogleService-Info.plist`
- `app/ios/Runner/GoogleService-Info.plist`

For the local iPhone build installed on 2026-05-08, these ignored files were generated locally with Omi's production Firebase project (`based-hardware`) so that Omi hosted custom tokens are accepted. That was a local build decision, not a committed ScoutPulse Firebase migration.

### Native iOS Capabilities In Source

The committed iOS app still declares the upstream capabilities in the dev/prod entitlements, including:

- Sign in with Apple
- Associated domains for Omi links
- HealthKit
- Wi-Fi/hotspot configuration
- App Groups for widget/shared state
- Push notification environment

For local installs signed with Adam's current certificate, some protected entitlements may be stripped locally to make the app install. This can affect push, associated domains, App Groups/battery widget state, HealthKit, and similar capabilities in that locally installed build. Do not treat the stripped local build as the final product capability model.

### iOS Native Integrations Present

The iOS app currently includes native bridges for:

- BLE/Omi device communication and recording control.
- Apple Watch companion communication.
- Battery widget shared-state writes through App Group user defaults.
- Apple Reminders action-item export.
- HealthKit read access service.
- Phone call support through native method channels.
- Firmware/DFU support through the mobile app dependencies and flows.
- Deep-link forwarding from AppDelegate to Dart for hosted auth callbacks.

## Work Completed In This Fork

### Hosted Google Auth Recovery

We restored the hosted Google auth path so the app can use Omi's backend auth flow instead of relying only on direct native Firebase Google sign-in.

Key behavior now present:

- The app can launch external hosted auth.
- iOS forwards `omi://auth/callback` deep links to Dart through the `com.omi/deep_links` channel.
- The app exchanges hosted auth codes for token payloads.
- The app supports Omi backend custom-token sign-in when `USE_AUTH_CUSTOM_TOKEN=true`.

Root cause found during testing: browser auth can be successful while app login fails if the app initializes a Firebase project that does not match the hosted backend's custom-token issuer. This is why local hosted-backend builds currently use Omi-compatible Firebase config.

### iOS Flavor Configuration Fixes

Committed on branch `codex/ios-narramind-config-guardrails`:

- `Profile-dev` now uses `Pods-Runner.profile-dev.xcconfig`.
- `Release-dev` now uses `Pods-Runner.release-dev.xcconfig`.
- Dev profile/release configs now explicitly resolve to `com.friend-app-with-wearable.ios12.development`.
- iOS configs now expose `GOOGLE_CLIENT_ID` as well as `GOOGLE_REVERSE_CLIENT_ID`.
- `Info.plist` now maps `GIDClientID` from the active flavor config.
- `RunnerProfile-dev.entitlements` no longer has the invalid `aps-environment=Devdevelopment` value.
- Setup and test bootstrap scripts default local hosted-auth setup to `https://api.omi.me/`.
- README and agent docs now warn about the hosted custom-token/Firebase project coupling.

Verification for that branch:

- `app/test.sh`: 449 Flutter tests passed.
- `plutil -lint`: iOS plist and entitlements passed.
- `pod install`: completed.
- `xcodebuild -showBuildSettings`: dev/prod bundle IDs and Google client IDs resolved as expected.

### Local iPhone Deployment

The current local iPhone deployment was built from:

- Branch: `codex/ios-narramind-config-guardrails`
- Commit: `d867c7711`
- Installed bundle: `com.friend-app-with-wearable.ios12.development`
- Backend: `https://api.omi.me/`
- Auth flags: `USE_WEB_AUTH=true`, `USE_AUTH_CUSTOM_TOKEN=true`
- Local Firebase project: Omi `based-hardware`

Packaged build:

```text
/Users/adam/dev/omi-builds/omi-ios-dev-hosted-prod-firebase-20260508-210531/Omi-Dev-iOS-hosted-prod-firebase-20260508-210531.ipa
```

The local deployment required machine-specific signing changes and temporary entitlement stripping. Those changes were cleaned from the worktree after install and are not part of the pushed branch.

### Other App Work Already Present Locally

Recent app work merged into this fork includes:

- Apple Reminders auto-export controls.
- Action item selection, indentation, bulk delete/export behavior.
- Conversation ID copy action.
- TestFlight/staging API switch support in settings.
- Token refresh and sign-out regression coverage.
- Phone-mic interruption handling improvements.
- Battery/widget, Apple Watch, HealthKit, and firmware-related code already present from the upstream app and local work.

## Current Constraints

### Hosted Backend Is Required

Do not switch local/dev builds away from `https://api.omi.me/` unless the task is explicitly to test another backend. The developer account is using Omi's paid backend service during development.

### No Private API Or BYOK Defaults

Do not commit personal API endpoints, custom backend URLs, private credentials, or user-specific AI provider keys into the app. Normal Omi AI/API access should keep routing through Omi's backend.

### Upstream Is Read-Only

Use upstream `BasedHardware/omi` only for fetch/merge/rebase. Do not open PRs to upstream. Push branches and PRs only to the user's fork.

### ScoutPulse/NarraMind Firebase Is Not Ready Yet

The desired product identity is leaning toward:

```text
Name: NarraMind
Base bundle: com.scoutpulse.narramind
```

That identity is not yet active in the committed iOS app because switching Firebase or bundle identity too early can break hosted Omi custom-token auth.

## Future Plan

### Phase 1: Stabilize The Omi-Hosted Development App

- Keep the current `Omi Dev` app working with `api.omi.me`.
- Keep using Omi-compatible Firebase config for local hosted custom-token builds.
- Keep local signing changes out of source.
- When auth fails, first check Firebase project alignment before changing backend URLs.
- Continue merging upstream Omi changes into this fork and compare conflicts carefully.

### Phase 2: Prepare ScoutPulse/NarraMind Apple Identity

Create Apple Developer portal identifiers and profiles for:

- `com.scoutpulse.narramind`
- `com.scoutpulse.narramind.dev`
- `com.scoutpulse.narramind.widget`
- Watch companion identifiers, if the watch app remains in scope.
- App Group identifiers, for example `group.com.scoutpulse.narramind`.

Capabilities to plan explicitly:

- Sign in with Apple.
- HealthKit read access.
- App Groups for battery widget/shared state.
- Apple Watch companion app support.
- Associated domains for any future NarraMind-owned web links.
- Push notifications only when the backend push model is ready; do not block the current Omi-hosted backend work on push.

### Phase 3: Decide Firebase/Auth Ownership

Before switching the app to a ScoutPulse Firebase project, choose one of these paths:

- Continue using Omi's Firebase project while the app uses Omi hosted backend custom tokens.
- Get Omi-hosted backend support for issuing custom tokens for a ScoutPulse Firebase project.
- Build a ScoutPulse backend/auth exchange later and then move away from Omi hosted custom tokens.

Until one of those is true, do not make `com.scoutpulse.narramind` + ScoutPulse Firebase the default for hosted `api.omi.me` builds.

### Phase 4: Productize NarraMind

After Apple identifiers and auth ownership are settled:

- Add first-class NarraMind dev/prod flavor config.
- Move signing to Adam/ScoutPulse certificates and profiles.
- Restore the capabilities that matter for the product: watch support, basic HealthKit, App Groups/battery widget state, and eventually push if needed.
- Keep Omi backend usage documented and explicit during the transition.
- Preserve upstream merge workflow so improvements from BasedHardware/Omi continue to land in this fork.

## Merge And Maintenance Workflow

Use this pattern for ongoing iOS work:

1. Fetch and fast-forward local `main` from the user's fork.
2. Fetch upstream `BasedHardware/omi`.
3. Merge or rebase upstream changes into a dedicated worktree branch.
4. Resolve conflicts by comparing upstream behavior with local fixes.
5. Keep changes scoped and commit on a feature branch.
6. Push only to `origin`.
7. Open/merge PRs only in the user's fork.
8. Never push directly to `main`.
9. Never submit PRs to upstream BasedHardware/Omi.

## Quick Diagnostic Checklist

If Google login fails after browser auth succeeds:

1. Confirm `.dev.env` or `.prod.env` uses `API_BASE_URL=https://api.omi.me/`.
2. Confirm `USE_WEB_AUTH=true`.
3. Confirm `USE_AUTH_CUSTOM_TOKEN=true`.
4. Confirm app Firebase project matches the Omi backend token issuer.
5. Confirm `omi://auth/callback` is registered in `Info.plist`.
6. Confirm AppDelegate forwards deep links to `com.omi/deep_links`.
7. Only then investigate token exchange responses or backend behavior.

If the local iPhone install fails:

1. Confirm the iPhone is unlocked and Developer Mode is enabled.
2. Confirm Xcode has the matching iOS platform installed.
3. Confirm the selected Apple team has a valid development certificate.
4. Strip protected entitlements only as a local install workaround, not as a source change.
5. Rebuild profile flavor and install the generated `Runner.app`.
