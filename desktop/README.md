# Omi Desktop

macOS app for Omi. The desktop product is a Swift/SwiftUI host app, a TypeScript agent runtime, and an optional Rust HTTP backend for desktop-specific services.

Most day-to-day desktop development should use the local app with Omi's hosted backends. That keeps the app on your local branch while auth, subscriptions, transcription, and desktop backend calls use the same cloud services as a normal Omi account.

## Prerequisites

- macOS 14 or newer.
- Xcode and Command Line Tools.
- Node.js and npm for `agent/`.
- Rust toolchain for `Backend-Rust/` only when running the local Rust backend.
- Python 3 only when working on deprecated `Auth-Python/`.
- `cloudflared` only when exposing a local Rust backend through a public tunnel.
- `libwebp` from Homebrew if SwiftPM cannot find WebP headers.
- Apple code-signing identity in the login keychain. `run.sh` auto-detects `Apple Development` or `Developer ID Application`; override with `OMI_SIGN_IDENTITY="..."`.

## Hosted Backend Mode

Use this mode for normal local testing with an Omi subscription:

```bash
cd desktop
./run.sh --yolo
```

This builds and installs `/Applications/Omi Dev.app`, then launches it with:

- `OMI_SKIP_BACKEND=1`
- `OMI_SKIP_TUNNEL=1`
- `OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc.a.run.app`
- `OMI_PYTHON_API_URL=https://api.omi.me`

No local `.env`, Rust backend, Cloudflare tunnel, or Auth-Python service is required. The app binary is local; the services are Omi-hosted.

## Local Backend Environment

Use this only when changing or debugging `Backend-Rust/`. Create the backend env first:

```bash
cd desktop/Backend-Rust
cp .env.example .env
```

Fill in the required values:

- `PORT=10201` for the Rust backend. Avoid 8080.
- `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, and `GOOGLE_APPLICATION_CREDENTIALS`.
- `ENCRYPTION_SECRET` for encrypted user data.
- `OMI_PYTHON_API_URL=https://api.omi.me` unless you are also running the Python backend locally.

For Swift app-only overrides, use `desktop/.env.app` or `~/.omi.env`. `Auth-Python/` is deprecated; use it only for legacy auth investigation.

## Run In Development

Recommended hosted mode:

```bash
./run.sh --yolo
```

The hosted runner:

1. Builds the TypeScript agent runtime.
2. Builds the Swift app.
3. Signs and installs `/Applications/Omi Dev.app`.
4. Writes hosted backend URLs into the bundled `.env`.
5. Launches the dev app.

Full local backend mode:

```bash
./run.sh
```

The full local runner loads `Backend-Rust/.env`, starts an optional Cloudflare tunnel, builds and starts `Backend-Rust/`, then builds, signs, installs, and launches the Swift app.

Useful variants:

```bash
OMI_SKIP_TUNNEL=1 ./run.sh
OMI_SKIP_BACKEND=1 OMI_DESKTOP_API_URL=https://desktop-backend.example.com ./run.sh
./run.sh --yolo
OMI_APP_NAME="search" ./run.sh
```

Named app builds must keep the app name and bundle suffix aligned. `OMI_APP_NAME="search"` produces `search.app`, bundle id `com.omi.search`, and URL scheme `omi-search`.

## Build Notes

Use the desktop runner for normal development. If you only need a Swift compile, use the Xcode toolchain command from the repo rules:

```bash
xcrun swift build -c debug --package-path Desktop
```

Do not use bare `swift build` from `desktop/`; it can pick the wrong SDK/toolchain.

## Signed DMG And Release

Local development builds are installed by `run.sh`. Production releases are created by CI:

1. GitHub Actions tags `desktop/**` changes.
2. Codemagic builds a universal binary, signs with Developer ID, notarizes, creates the DMG and Sparkle ZIP, uploads artifacts, and registers release metadata.
3. Sparkle serves updates from the Rust backend appcast route.

DMG resources live in `dmg-assets/`. Release entitlements live in `Desktop/Omi-Release.entitlements`.

## Test Auto-Update Locally

- Build and sign a release-style app with the same bundle id and Sparkle public key as the target channel.
- Serve an appcast from a local or staging Rust backend using `/appcast.xml?platform=macos`.
- Register release metadata through `/updates/releases` with `X-Release-Secret: $RELEASE_SECRET`.
- Verify `sparkle:edSignature`, `download_url`, `channel`, and `build_number` before launching the app.
- Use Settings -> Software Updates, or call Sparkle through the in-app update UI.

If Sparkle reports a code-signature/provenance failure, check quarantine/provenance attributes on the downloaded app and DMG:

```bash
xattr -l /path/to/Omi.app
xattr -dr com.apple.quarantine /path/to/Omi.app
```

## Reset macOS Permissions For Testing

Use the bundle id for the exact build under test:

```bash
BUNDLE_ID=com.omi.desktop-dev
tccutil reset ScreenCapture "$BUNDLE_ID"
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID"
tccutil reset AppleEvents "$BUNDLE_ID"
```

For named builds, replace `BUNDLE_ID` with `com.omi.<name-slug>`. After resetting Screen Recording, quit and reopen the installed app from `/Applications/` so TCC attaches the grant to the canonical bundle.

## Logs

- Dev app log: `/private/tmp/omi-dev.log`
- Production app log: `/private/tmp/omi.log`
- Auth runner debug log: `/private/tmp/auth-debug.log` when using deprecated `Auth-Python/`

## Troubleshooting

- Missing backend credentials: use `./run.sh --yolo` for hosted mode, or copy a service account JSON to `desktop/Backend-Rust/google-credentials.json` when running the local Rust backend.
- OAuth callback opens the wrong app: remove stale copies from Downloads/Desktop, run `./run.sh`, and verify the named bundle id and URL scheme match.
- Screen Recording says granted but capture fails: reset ScreenCapture for the active bundle id, reinstall through `run.sh`, then grant again in System Settings.
- Menu bar icon is missing or generic: remove stale DMG/app copies and relaunch from `/Applications/`.
- Auth works once then fails after rebuild: confirm `FIREBASE_API_KEY` and `OMI_PYTHON_API_URL` are present in the env copied into the app bundle.
- Rust backend fails immediately: check `PORT`, `FIREBASE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, and `ENCRYPTION_SECRET`.
