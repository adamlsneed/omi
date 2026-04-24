# Omi Desktop

macOS app for Omi. The desktop product is a Swift/SwiftUI host app plus a Rust HTTP backend, a local Python OAuth broker for development, and a TypeScript agent runtime.

## Prerequisites

- macOS 14 or newer.
- Xcode and Command Line Tools.
- Rust toolchain for `Backend-Rust/`.
- Python 3 for `Auth-Python/`.
- Node.js and npm for `agent/`.
- `cloudflared` if local OAuth callbacks or remote device testing need a public tunnel.
- `libwebp` from Homebrew if SwiftPM cannot find WebP headers.
- Apple code-signing identity in the login keychain. `run.sh` auto-detects `Apple Development` or `Developer ID Application`; override with `OMI_SIGN_IDENTITY="..."`.

## Environment

Create the backend env first:

```bash
cd desktop/Backend-Rust
cp .env.example .env
```

Fill in the required values:

- `PORT=10201` for the Rust backend. Avoid 8080.
- `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, and `GOOGLE_APPLICATION_CREDENTIALS`.
- `ENCRYPTION_SECRET` for encrypted user data.
- OAuth values used by both `Backend-Rust/` and `Auth-Python/`: `BASE_API_URL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and optional Apple Sign-In values.

For Auth-Python-only deployment, use `desktop/Auth-Python/.env.example`. For Swift app-only overrides, use `desktop/.env.example` or `~/.omi.env`.

## Run In Development

From `desktop/`:

```bash
./run.sh
```

The runner:

1. Loads `Backend-Rust/.env`.
2. Starts an optional Cloudflare tunnel.
3. Builds and starts `Backend-Rust/`.
4. Starts `Auth-Python/` on `AUTH_PORT` (default `10200`).
5. Builds the Swift app, signs it, installs it to `/Applications/Omi Dev.app`, and launches it.

Useful variants:

```bash
OMI_SKIP_TUNNEL=1 ./run.sh
OMI_SKIP_BACKEND=1 OMI_API_URL=https://desktop-backend.example.com ./run.sh
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
- Auth runner debug log: `/private/tmp/auth-debug.log`

## Troubleshooting

- Missing backend credentials: copy a service account JSON to `desktop/Backend-Rust/google-credentials.json` or set `GOOGLE_APPLICATION_CREDENTIALS`.
- OAuth callback opens the wrong app: remove stale copies from Downloads/Desktop, run `./run.sh`, and verify the named bundle id and URL scheme match.
- Screen Recording says granted but capture fails: reset ScreenCapture for the active bundle id, reinstall through `run.sh`, then grant again in System Settings.
- Menu bar icon is missing or generic: remove stale DMG/app copies and relaunch from `/Applications/`.
- Auth works once then fails after rebuild: confirm `FIREBASE_API_KEY`, `OMI_AUTH_URL`, and `BASE_API_URL` are present in the env copied into the app bundle.
- Rust backend fails immediately: check `PORT`, `FIREBASE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, and `ENCRYPTION_SECRET`.
