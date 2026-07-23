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
cd desktop/macos
./run.sh --yolo

# Keep one explicit focused regression test running after each save
./scripts/dev-feedback.py --watch swift 'ChatTests/testSendsMessage'
./scripts/dev-feedback.py --watch rust 'handles_timeout'

# Relaunch an already-built named app without holding the terminal open.
# Supply a harness/external backend; --no-wait deliberately does not own one.
OMI_SKIP_BACKEND=1 OMI_APP_NAME="omi-subagent-test" ./run.sh --yolo --fast-only --no-wait

# Force a complete bundle refresh after changing packaged runtime inputs
./run.sh --full
```

This builds and installs `/Applications/Omi Dev.app`, then launches it with:

- `OMI_SKIP_BACKEND=1`
- `OMI_SKIP_TUNNEL=1`
- `OMI_DESKTOP_API_URL=https://desktop-backend-hhibjajaja-uc.a.run.app`
- `OMI_PYTHON_API_URL=https://api.omi.me`

No local `.env`, Rust backend, Cloudflare tunnel, or Auth-Python service is required. The app binary is local; the services are Omi-hosted.

After a successful full launch, `run.sh` automatically uses its fast lane for ordinary Swift-only edits: it incrementally builds Swift, patches the already-installed app executable plus the current desktop API URL, re-signs it, and relaunches. Named local-harness profiles are eligible too; their current disposable `.env` is refreshed on every fast patch rather than cached. Changing package metadata, bundled resources, agent/runtime inputs, entitlements, or persistent launch configuration safely falls back to the complete packaging path. Use `./run.sh --full` (or `OMI_FORCE_FULL_BUNDLE=1`) to force that path; set `OMI_SCAN_STALE_BUNDLES=1` only when recovering from stale LaunchServices registrations.

`dev-feedback.py` is the fast test loop: pass an explicit XCTest or Cargo filter, use `--once` for one check or `--watch` to rerun after relevant saves. It never guesses coverage and never replaces `./test.sh`, which remains the full component/PR suite. That suite now runs its isolated Swift suites with four workers by default; use `OMI_SWIFT_TEST_SUITE_WORKERS=1` only when diagnosing concurrency-sensitive behavior. For a direct local Rust backend, `run.sh` now uses Cargo debug builds and reuses a healthy worktree-owned backend on Swift-only relaunches. Set `OMI_DESKTOP_BACKEND_RELEASE=1` only when locally checking optimized backend behavior. Add `--no-wait` only when a harness or other external backend owns the API; it returns after the app launch instead of holding the terminal for launcher-managed processes.

`git push` is the bounded desktop acceptance gate: desktop source changes run only the fast `xcrun swift build -c debug --package-path Desktop` check on the installed Xcode. This is intentionally less than CI: the four-worker Swift suite, clean release compile, and pinned `/Applications/Xcode_16.4.app` (Xcode 16.4 build 16F6) belong to GitHub Actions. Do not move those CI jobs into pre-push; preserving push-time budget keeps normal iteration fast. Use `dev-feedback.py --watch` while editing.

Named bundles derive an isolated bundle ID and OAuth callback URL scheme from `OMI_APP_NAME`. `Omi Dev` keeps `com.omi.desktop-dev` / `omi-computer-dev`, while `OMI_APP_NAME="omi-subagent-test"` uses `com.omi.omi-subagent-test` / `omi-omi-subagent-test`. The app reads that scheme from `CFBundleURLTypes` for OAuth redirects, so parallel dev bundles do not claim the canonical `omi-computer-dev` callback.

## Local Backend Environment

Use this only when changing or debugging `Backend-Rust/`. Create the backend env first:

```bash
cd desktop/macos/Backend-Rust
cp .env.example .env
```

Fill in the required values:

- `PORT=10201` for the Rust backend. Avoid 8080.
- `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, and `GOOGLE_APPLICATION_CREDENTIALS`.
- `ENCRYPTION_SECRET` for encrypted user data.
- `OMI_PYTHON_API_URL=https://api.omi.me` unless you are also running the Python backend locally.

For Swift app-only overrides, use `desktop/macos/.env.app` or `~/.omi.env`. `Auth-Python/` is deprecated; use it only for legacy auth investigation.

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
```

Local deploys always target "Omi Dev" (`/Applications/Omi Dev.app`, bundle id `com.omi.desktop-dev`), replacing the existing install. Do not use `OMI_APP_NAME` to deploy under another name. When the user asks to install the macOS app locally, interpret that as installing over the existing Omi Dev app unless they explicitly request a separate named build.

## Build Notes

Use the desktop runner for normal development. If you only need a Swift compile, use the Xcode toolchain command from the repo rules:

```bash
xcrun swift build -c debug --package-path Desktop
```

Do not use bare `swift build` from `desktop/macos/`; it can pick the wrong SDK/toolchain.

## Signed Release (fork)

Local development builds are installed by `run.sh`. Upstream's CI release pipeline
(GitHub Actions tag + Codemagic + Sparkle) is disabled in this fork; releases are cut
manually with `./release.sh --bump` and distributed via Homebrew. See [`RELEASE.md`](RELEASE.md).

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

- Missing backend credentials: use `./run.sh --yolo` for hosted mode, or copy a service account JSON to `desktop/macos/Backend-Rust/google-credentials.json` when running the local Rust backend.
- OAuth callback opens the wrong app: remove stale copies from Downloads/Desktop, run `./run.sh`, and verify the bundle id and URL scheme match.
- Screen Recording says granted but capture fails: reset ScreenCapture for the active bundle id, reinstall through `run.sh`, then grant again in System Settings.
- Menu bar icon is missing or generic: remove stale DMG/app copies and relaunch from `/Applications/`.
- Auth works once then fails after rebuild: confirm `FIREBASE_API_KEY` and `OMI_PYTHON_API_URL` are present in the env copied into the app bundle.
- Rust backend fails immediately: check `PORT`, `FIREBASE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, and `ENCRYPTION_SECRET`.
