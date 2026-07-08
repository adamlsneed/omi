# Desktop (macOS) — Developer Guide

## Project Overview
OMI Desktop App for macOS (Swift)

## Logs & Debugging

### Local App Logs
- **App log file**: `/private/tmp/omi.log` (production) or `/private/tmp/omi-dev.log` (dev builds)

### Release Health (Sentry)
Check errors in the latest (or specific) release using the **sentry-release skill**:
```bash
./scripts/sentry-release.sh              # new issues in latest version (default)
./scripts/sentry-release.sh --version X  # specific version
./scripts/sentry-release.sh --all        # include carryover issues
./scripts/sentry-release.sh --quota      # billing/quota status
```
See `.claude/skills/sentry-release/SKILL.md` for full documentation.

### User Issue Investigation
When debugging issues for a specific user, check Sentry dashboard for crashes and PostHog for events.

## Repository
- This is the `desktop/macos/` subfolder of the **OMI monorepo** (`BasedHardware/omi`)
- macOS Swift app + Rust backend live here

## Release Pipeline (fork)

> This fork does NOT auto-release. Upstream's Codemagic/auto-release workflows
> were removed, so merging `desktop/macos/**` to `main` only lands code — it builds and
> ships nothing. The old "merge → Codemagic → Sparkle" flow no longer applies.

Releases are cut manually and distributed via Homebrew. **Full guide: [`RELEASE.md`](RELEASE.md).**

- Cut a release: `cd desktop/macos && ./release.sh --bump` (builds `-c release`, signs with
  Developer ID + `Omi-Release.entitlements`, notarizes, publishes a GitHub Release on
  `adamlsneed/omi`, and bumps the Homebrew cask in `adamlsneed/homebrew-omi`).
- Install/update on a Mac: `brew install --cask adamlsneed/omi/omi` then `brew upgrade`.
- This dev Mac keeps using `./run.sh` (debug build) for development.

`release.sh` mirrors `run.sh`'s bundle assembly; keep them in sync if `run.sh`'s
assembly changes on an upstream pull.

## Firebase Connection
Use `/firebase` command or see `.claude/skills/firebase/SKILL.md`

Quick connect:
```bash
cd ../backend && source venv/bin/activate && python3 -c "
import firebase_admin
from firebase_admin import credentials, firestore, auth
cred = credentials.Certificate('google-credentials.json')
try: firebase_admin.initialize_app(cred)
except ValueError: pass
db = firestore.client()
print('Connected to Firebase: based-hardware')
"
```

## Module Layout (SwiftPM)

`Desktop/Package.swift` is incrementally splitting the monolithic executable into
library targets with enforced dependency edges:

- `OmiTheme` — shared colors, typography, chrome (`Sources/Theme/`)
- `OmiWAL` — write-ahead log model + coordinator (`Sources/OmiWAL/`)
- `OmiSupport` — shared desktop runtime helpers (`Sources/OmiSupport/`, e.g. `DesktopLocalProfile`)

`Rewind/Core/` remains in the executable target for now — it still references main-app
types (`TaskActionItem`, `PowerMonitor`, etc.) and needs a shared-models carve-out first.

**Do not add new `.swift` files directly under `Desktop/Sources/`.** Place new
code in a feature directory (`Onboarding/`, `MainWindow/`, `Chat/`, etc.). CI
enforces this via `scripts/check-sources-root-layout.py`.

When carving out additional leaf modules, prefer bottom-up order (models and
storage before UI) and wire `import` + `public` on the extracted target's API.

## Key Architecture Notes

### Authentication
- Firebase Auth with Apple/Google Sign-In
- Desktop apps should use backend OAuth flow: `/v1/auth/authorize`
- Apple Services ID: `me.omi.web` (shared across all apps)
- iOS apps use native Sign-In, Desktop uses backend OAuth + custom token

### Database Structure
- **Firestore** (`based-hardware`): User data, conversations, action items
- **Redis**: Caching
- **Typesense**: Search

### User Subcollections (Firestore)
- `users/{uid}/conversations` - Has `source` field (omi, desktop, phone, etc.)
- `users/{uid}/action_items` - Tasks (no platform tracking)
- `users/{uid}/fcm_tokens` - Token ID prefix = platform (ios_, android_, macos_)
- `users/{uid}/memories` - Extracted memories

### Platform Detection
- **FCM tokens**: Document ID prefix (e.g., `macos_abc123`)
- **Conversations**: `source` field
- **Action items**: No platform tracking

### Known Limitations
- Firestore has no collection group indexes for `source` field
- Counting users by platform requires iterating all users (slow)
- Apple Sign-In: Only one Services ID per Firebase project

## API Endpoints
- Production: `https://api.omi.me`
- Local: `http://localhost:8080`

## Credentials
See `.claude/settings.json` for connection details.

## Development Workflow

### Building & Running
- **No Xcode project** — this is a Swift Package Manager project
- **Build command**: `xcrun swift build -c debug --package-path Desktop` (the `xcrun` prefix is required to match the SDK version)
- **Full dev run**: `./run.sh` — builds Swift app, starts Rust backend, starts Cloudflare tunnel, launches app
- **Release builds**: `cd desktop/macos && ./release.sh --bump` (notarized + Homebrew; see `RELEASE.md`). Not Codemagic.
- **DO NOT** use bare `swift build` — it will fail with SDK version mismatch
- **DO NOT** use `xcodebuild` — there is no `.xcodeproj`
- **DO NOT** launch the app directly from `build/` — always use `./run.sh` or `./reset-and-run.sh`. These scripts install to `/Applications/Omi Dev.app` and launch from there, which is required for macOS "Quit & Reopen" (after granting permissions) to find the correct binary. Launching from `build/` causes stale binaries to run after permission restarts.
- **DO NOT** manually copy binaries into app bundles and launch them — this bypasses signing, `/Applications/` installation, and LaunchServices registration

- **DO NOT** kill, delete, or interfere with running "Omi", "omi", or "Omi Beta" app bundles — these are production/release installs the user relies on

### App Names & Build Artifacts
- `./run.sh` builds **"Omi Dev"** → installs to `/Applications/Omi Dev.app` (bundle ID: `com.omi.desktop-dev`)
- **"Omi Beta"** (bundle ID: `com.omi.computer-macos`) is built by Codemagic CI only
- To check which app is currently running: `ps aux | grep "Omi"`

### Local Deploys Always Target "Omi Dev"
When testing a feature or bug fix, **always deploy as "Omi Dev" on top of the existing install**:
```bash
./run.sh
```
This rebuilds and replaces `/Applications/Omi Dev.app` (bundle ID: `com.omi.desktop-dev`). Permissions, database, and auth state persist across deploys, so once signed in it boots already-signed-in.

**Rules:**
- **NEVER use `OMI_APP_NAME` for local deploys** — do not create named bundles (`omi-<feature>` etc.); always deploy as "Omi Dev" over the existing install
- To connect agent-swift: `agent-swift connect --bundle-id com.omi.desktop-dev`
- **Jump to a screen without clicking:** the automation bridge auto-enables on non-prod bundles — `./scripts/omi-ctl navigate <screen>` (e.g. `rewind`, `memories`, `settings rewind`). See "Fast-Path for Local Iteration" in `e2e/SKILL.md`.

### After Implementing Changes
- `xcrun swift build` is for **compile checks only** — it does NOT start the backend
- To actually test, ALWAYS use `./run.sh` (deploys as "Omi Dev") — it starts Rust backend + Cloudflare tunnel + Swift app together
- **When the user says "test it"**, use the `test-local` skill to build, run, and verify via macOS automation

### Agent Logic Harness
When touching desktop agent runtime, floating agent pills, realtime hub, PTT, or `pi-mono-extension`, run the focused harness before broader checks:
```bash
cd desktop/macos && ./scripts/agent-logic-harness.sh
```
It is self-driving for agents: it runs the risky Swift lifecycle/state tests, focused agent runtime tests, exact `pi-mono-extension` package tests, and prints per-step runtime. Use `--swift-only`, `--node-only`, or `--skip-install` only when narrowing a failure.

### Verifying UI Changes (agent-swift)

After editing Swift UI code, verify the change programmatically using [agent-swift](https://github.com/beastoin/agent-swift) — a CLI that controls any macOS app via the Accessibility API.

**One-time setup:** `brew install beastoin/tap/agent-swift` + grant Accessibility permission to Terminal.app.

```bash
# After ./run.sh launches the app:
agent-swift doctor                                   # verify Accessibility permission
agent-swift connect --bundle-id com.omi.desktop-dev  # connect to running app
agent-swift snapshot -i                              # see interactive elements
agent-swift click @e3                                # CGEvent click (SwiftUI)
agent-swift press @e3                                # AXPress (AppKit buttons)
agent-swift fill @e5 "search text"                   # type into a text field
agent-swift find role button click                   # find + chained action
agent-swift is exists @e3                            # assert element exists (exit 0/1)
agent-swift wait text "Settings"                     # wait for text to appear
agent-swift screenshot /tmp/evidence.png             # capture app window
```

**Key rules:**
- Always use `snapshot -i` (interactive only) — full snapshot of a complex SwiftUI app is extremely verbose.
- Prefer `click` over `press` for SwiftUI — `click` sends CGEvent clicks (triggers NavigationLink), `press` sends AXPress (AppKit only).
- Refs go stale after `click`/`press`/`fill`/`scroll` — re-snapshot before the next interaction.
- Argument order: `get <property> <ref>`, `is <condition> <ref>`, `wait <condition> [<target>]`, `find <locator> <value>`.
- 15 commands: `doctor`, `connect`, `disconnect`, `status`, `snapshot`, `press`, `click`, `fill`, `get`, `find`, `screenshot`, `is`, `wait`, `scroll`, `schema`.
- No app-side instrumentation needed — works via macOS Accessibility API on any Cocoa/SwiftUI app.
- Dev bundle ID: `com.omi.desktop-dev`. Prod: `com.omi.computer-macos` (never automate prod).

### Changelog Entries

After completing a desktop task with user-visible impact, add one fragment file under `desktop/macos/changelog/unreleased/`:

Example `desktop/macos/changelog/unreleased/20260628-short-description.json`:

```json
{
  "change": "Your user-facing change description"
}
```

Guidelines:
- Write from the user's perspective: "Fixed X", "Added Y", "Improved Z"
- One sentence, no period at the end
- Use a unique kebab-case filename so parallel PRs do not conflict
- Skip internal-only changes (refactors, CI config, code cleanup)
- HTML is allowed for links: `<a href='...'>text</a>`
- Do not edit `CHANGELOG.json` by hand; release automation regenerates it
- Commit the fragment with your other changes (same commit is fine)

## User Task Completion Reporting

When completing a task that was triggered by an app user request (bug report, feature request, support inquiry, etc.) and you have the user's email address, **send them an email about the results** using the `omi-email` skill:

```bash
node ../omi-analytics/scripts/send-email.js \
  --to "<user-email>" \
  --subject "<brief result summary>" \
  --body "<what was done, what they should expect, any next steps>"
```

- Write as Matt (first person "I", not "we") — the user already has an ongoing email thread with us, so treat this as a casual continuation of that conversation, not a fresh introduction
- Be concise and direct — they know the context, just share what was done and any next steps (e.g. "update the app")
- Only send when there are meaningful results to share (don't email for internal-only changes)
