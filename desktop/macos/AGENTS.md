# Desktop (macOS) — Developer Guide

## Project Overview
OMI Desktop App for macOS (Swift). This is the `desktop/macos/` subfolder of the
**OMI monorepo** (`BasedHardware/omi`); the shared Python desktop backend lives
under `../../backend`.

## Logs & Debugging

For difficult SwiftUI/AppKit runtime bugs—stale views, lost input, layout loops, jumps, beachballs, or fast-interaction failures—follow [`docs/swiftui-appkit-runtime-debugging.md`](docs/swiftui-appkit-runtime-debugging.md).

### Local App Logs
- **App log file**: `/private/tmp/omi.log` (production). Each non-production
  launch writes to its own owner-only log; ask the running named bundle for its
  exact path with `./scripts/omi-ctl log-path` rather than reading a shared dev log.

### User Issue Investigation
When debugging issues for a specific user, check PostHog events, the local log, and the
diagnostics ring buffer. Desktop crash reporting was removed together with Sentry; the
release lane retains the UUID-verified dSYM as a GitHub release artifact for offline
symbolication. Firebase quick-connect snippet (project `based-hardware`):
[`docs/firebase-connection.md`](docs/firebase-connection.md).

### Product analytics integrity

The full measurement contract lives in [`docs/analytics-integrity.md`](docs/analytics-integrity.md). Hard rules that always apply:

- PostHog receives bounded dimensions and shape metadata only. Never send raw
  prompts, responses, notification/window titles, filesystem paths, or exception
  messages. Keep diagnostic detail in the private local log.
- Production `QueryTracer` output is shape-only and stored under a `0700`
  directory in `0600` files. Full prompt/response/tool content is a deliberate
  non-production debugging capability only.
- Product authority is independent from telemetry. Revoked or timed-out turns
  cannot apply late callbacks/results or persist a late response even if
  analytics is disabled or refactored.

### Fallback / resilience telemetry
Provider/mode switches and fail-open paths must call `DesktopDiagnosticsManager.recordFallback(area:from:to:reason:outcome:)` (PostHog `desktop_health_event` / `fallback_triggered`) or Rust `fallback::record_fallback`. Field contract: [`.github/agent-docs/fallback-telemetry.md`](../../.github/agent-docs/fallback-telemetry.md). Do not invent new health-event enum cases or product “Recording Error” events for successful heals (`outcome=recovered`).

Gemini Live has no safe mid-session system role. Background agent/card text stays on its canonical tool or visible UI surface and must never use Gemini's realtime user-input wire.

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

## Module Layout (SwiftPM)

`Desktop/Package.swift` is incrementally splitting the monolithic executable into
library targets with enforced dependency edges:

- `OmiTheme` — shared colors, typography, chrome (`Sources/Theme/`)
- `OmiWAL` — write-ahead log model + coordinator (`Sources/OmiWAL/`)
- `OmiSupport` — shared desktop runtime helpers (`Sources/OmiSupport/`, e.g.
  `DesktopLocalProfile` and `Dictionary(lastWriteWins:)`)

`Rewind/Core/` remains in the executable target for now — it still references main-app
types (`TaskActionItem`, `PowerMonitor`, etc.) and needs a shared-models carve-out first.

**Do not add new `.swift` files directly under `Desktop/Sources/`.** Place new
code in a feature directory (`Onboarding/`, `MainWindow/`, `Chat/`, etc.). CI
enforces this via `scripts/check-sources-root-layout.py`.

When carving out additional leaf modules, prefer bottom-up order (models and
storage before UI) and wire `import` + `public` on the extracted target's API.

### Bundled resources

`.process("Resources")` caches its manifest: after adding a file under
`Sources/Resources/`, touch `Desktop/Package.swift` or the build silently omits it.
It may flatten subdirectories — search both roots (`OmiSoundAssetLocator`), never
`Bundle.module`. Cinematic audio is generated: `scripts/make-onboarding-sounds.py`.

### Swift Formatting & SwiftLint

Swift formatting uses a pinned `swift-format` and SwiftLint a SHA-256-verified
0.65.0 release, each driven by its wrapper: `./scripts/swift-format-wrapper.sh
bootstrap`, then `lint -r $(./scripts/swift-format-wrapper.sh scope)`; and
`./scripts/swiftlint-wrapper.sh lint`. The wrappers own their pins, scope, and
usage. Format config lives at `Desktop/.swift-format` (2-space indent, 120-column
limit); generated sources under `Desktop/Sources/Generated/` and test fixtures
are excluded from both. The committed SwiftLint baseline is down-only; the
wrapper materializes a temporary baseline rooted at the current checkout before
linting — do not hand-edit those paths to match a specific machine. Manual
formatting commands:
[`.github/agent-docs/formatting.md`](../../.github/agent-docs/formatting.md).

### Synchronous state-machine callbacks

- A reducer transition is atomic through model assignment, effect delivery, UI
  projection, and snapshot publication. A callback may request another event,
  but it must not recursively reduce against a half-published transition.
- Coordinators with synchronous effect/snapshot callbacks drain nested events
  through a FIFO, non-reentrant queue. Do not fix recursion with one-off boolean
  suppression or by dispatching after an arbitrary delay.
- Tests for callback-driven machines must synchronously enqueue from both an
  effect callback and an observer/snapshot callback, assert callback depth stays
  one, and assert the resulting event order.

### Collection safety

- Never use `Dictionary(uniqueKeysWithValues:)` for API responses, decoded
  persistence, runtime projections, or any other data whose key uniqueness is
  not enforced by the Swift type system. A duplicate key traps and terminates
  the process.
- Use `Dictionary(lastWriteWins:)` from `OmiSupport` when the newest record in
  input order is authoritative. Use another explicit non-trapping merge policy
  when the domain requires different semantics.
- A raw trapping initializer is allowed only for a statically proven uniqueness
  contract, with a local reason:
  `// omi-collection-safety: static-unique-keys -- <why the type guarantees uniqueness>`.
  Runtime validation, backend expectations, and “should be unique” are not
  static contracts.
- Run `python3 scripts/check_desktop_test_quality.py` after changing Swift
  collection construction.

### Swift test quality

- Behavior fixes require tests that call the production API and assert outcomes.
  Reading a production `.swift` file and asserting that it contains a function
  name or implementation string is not behavioral coverage. Source inspection is
  reserved for narrow forbidden-pattern or static wiring tripwires that
  supplement — never replace — behavioral coverage, each with a local reason:
  `// omi-test-quality: source-inspection -- static contract: <what cannot be expressed behaviorally>`.
- Do not add wall-clock sleeps to unit tests. Inject a `Clock`/sleeper, drive a
  callback/continuation, or await a deterministic state signal. An unavoidable
  real-scheduler integration wait needs
  `// omi-test-quality: wall-clock-wait -- <why injection cannot test this boundary>`.
- `python3 scripts/check_desktop_test_quality.py` ratchets both categories.
  Shared fixtures and the ratchet: [test isolation guide](../../.github/agent-docs/desktop-test-isolation.md).

## Key Architecture Notes

### Authentication
- Firebase (Apple/Google); desktop OAuth: `/v1/auth/authorize`
- Apple Services ID: `me.omi.web` (shared across all apps)
- iOS apps use native Sign-In, Desktop uses backend OAuth + custom token
- Session death is owned by `AuthSessionCoordinator` (`INV-AUTH-1`); use `invalidateSession` for expired/revoked Firebase creds, not nuclear `signOut()`.

- [Agent credentials](docs/agent-model-credentials.md).

#### Session 401 vs BYOK/provider 401

| Failure class | Owner | Action on 401 after forced refresh |
|---------------|-------|-----------------------------------|
| Firebase session token (default API `Authorization`) | `AuthSessionCoordinator` | `invalidateSession` → Sign-in CTA |
| BYOK provider key on request | `CredentialHealthManager` | Suppress/mark provider unhealthy; **do not** invalidate Firebase session |
| Realtime/voice managed lane | `CredentialHealthManager` + hub UX | `requiresLogin` only when session mint fails after refresh |
| Background poll with `RequestAuthPolicy.sessionPreserving` | Caller | Throw `.unauthorized`; no session invalidation |
| `DesktopLocalProfile` harness | Auth emulator bootstrap | Re-bootstrap emulator session; no prod invalidation side effects |

### On-device tool surface
- Contacts/Messages/AppleScript actuation goes through kernel policy, never improvised shell; `desktop.messaging.read` is sensitive like `send` (a thread exposes the other party); `desktop.automation.act` never resolves without a dispatch or scoped grant; untrusted values reach `osascript` as `argv` only. `OMI_MESSAGES_DB` overrides the Messages store for tests. See `desktop/macos/docs/device-tool-surface.md`.

### Storage model
- **Firestore** (`based-hardware`): user data, conversations, action items. **Redis**: caching. **Typesense**: search.
- `users/{uid}/conversations` - Has `source` field (omi, desktop, phone, etc.)
- `users/{uid}/action_items` - Tasks (no platform tracking)
- `users/{uid}/fcm_tokens` - Token ID prefix = platform (ios_, android_, macos_)
- `users/{uid}/memories` - Extracted memories

### Screen activity sync rollout

- `screen_activity_lossless_sync` enables durable per-row delivery, five-minute `(app, window)` compaction, and bounded embedding recovery. Production-family bundles wait for that PostHog flag; non-production dogfoods it (`OMI_FORCE_LOSSLESS_SCREEN_SYNC=0` off).
- OCR-bearing rows sync independently from embeddings. Embeddings are an optional later projection and must never gate capture, OCR, or text delivery.
- Firestore screen-activity timestamps use the lexicographically sortable UTC form `yyyy-MM-dd HH:mm:ss.SSS`. The backend normalizes ISO-8601 input before storage.
- Local embeddings: [ARCHITECTURE.md](Desktop/Sources/LocalInference/ARCHITECTURE.md).

### Feature-flag authority

Bundle vs PostHog vs `runtime_env` is catalogued in [`backend/docs/feature-flag-registry.md`](../../backend/docs/feature-flag-registry.md). Editing that file does not turn a feature on. Do not target Beta vs stable via PostHog person `update_channel`.

### User MCP Servers & Skills (Apps page)
User-managed MCP servers (~/.omi/mcp.json, incl. native OAuth) and skills
(`~/.omi/skills/<slug>/SKILL.md`), fully local and fail-open. Contract and
runtime wiring: [`.github/agent-docs/desktop-user-extensions.md`](../../.github/agent-docs/desktop-user-extensions.md).

### Known Limitations
- Firestore has no collection group indexes for `source`; counting users by platform is a full scan
- Apple Sign-In: Only one Services ID per Firebase project

## Development Workflow

### Building & Running
- **No Xcode project** — this is a Swift Package Manager project
- **Build command**: `xcrun swift build -c debug --package-path Desktop` (the `xcrun` prefix is required to match the SDK version)
- `run.sh` prepends the native Homebrew prefix (`/opt/homebrew/bin` on Apple Silicon or `/usr/local/bin` on Intel), because agent and launchd shells may not inherit Homebrew's PATH — this keeps `pkg-config` and other build tools discoverable without a machine-wide shell profile change.
- **Full dev run**: `./run.sh` — builds Swift app, starts Python backend, starts Cloudflare tunnel, launches app
- Fast-lane behavior (incremental patch/re-sign/relaunch, when it falls back to a
  full bundle, the focused `dev-feedback.py` loop, suite worker isolation, and
  the agent-runtime preparation caches) is documented in [`README.md`](README.md)
  — read it before assuming you need a full rebuild, and never launch the app
  only to obtain compile evidence.
- **Local Python backend**: direct `./run.sh` reuses a healthy worktree-owned backend when Python source/config are unchanged. Sync deps with `cd ../../backend && ./scripts/sync-python-deps.sh` before first launch.
- **Agent runtime preparation cache**: local `./run.sh` calls reuse validated agent packaging from the worktree-local `.harness/agent-runtime` cache when source, locks, preparation logic, pinned runtime, mode, OS/architecture, Node/npm versions, and every file copied from the prepared runtime are unchanged. Hits verify the complete agent `dist`, both packaged dependency trees, their symlinks, and staged Node; working `agent/node_modules` is not hashed. Logs `Cache HIT`/`MISS`/`BYPASS`; hits preserve output mtimes but spend roughly a second hashing packaged outputs for integrity. CI and `--skip-npm` always bypass the stamp. Set `OMI_AGENT_RUNTIME_FORCE_REBUILD=1` for an explicit local rebuild. Do not copy this cache between worktrees or treat it as a release artifact. The checksum-verified universal Node archives are shared at `~/Library/Caches/OmiDesktop/node-archives` (override with `OMI_AGENT_RUNTIME_ARCHIVE_CACHE_DIR`). Cached at `~/Library/Caches/OmiDesktop/node-runtime`; see README.
- **Release builds**: `cd desktop/macos && ./release.sh --bump` (notarized + Homebrew; see `RELEASE.md`). Not Codemagic.
- **DO NOT** use bare `swift build` — it will fail with SDK version mismatch
- **DO NOT** use `xcodebuild` — there is no `.xcodeproj`
- **DO NOT** launch from `build/` or hand-copy binaries into a bundle — always `./run.sh`. It installs to `/Applications/`, signs, and registers with LaunchServices; `build/` binaries go stale after a permission restart.
- **Code signing**: local entitlements key on the identity's Team ID, not its name. **Never** use `OMI_ALLOW_ADHOC_SIGN=1` to fix a launch failure — it kills that bundle's Screen Recording grant. [`docs/local-code-signing.md`](docs/local-code-signing.md)

- **DO NOT** kill, delete, or interfere with running "Omi", "omi", or "Omi Beta" app bundles — these are production/release installs the user relies on

### App Names & Build Artifacts
- `./run.sh` builds **"Omi Dev"** → installs to `/Applications/Omi Dev.app` (bundle ID: `com.omi.desktop-dev`)
- **"Omi"** stable (bundle ID: `com.omi.computer-macos`) and **"Omi Beta"** (bundle ID: `com.omi.computer-macos.beta`, isolated "Omi Beta" storage root, runs side-by-side with stable) are built by Codemagic CI only

### Local Deploys Always Target "Omi Dev"
When testing a feature or bug fix, **always deploy as "Omi Dev" on top of the existing install**:
```bash
./run.sh
```
This rebuilds and replaces `/Applications/Omi Dev.app` (bundle ID: `com.omi.desktop-dev`). Permissions, database, and auth state persist across deploys, so once signed in it boots already-signed-in.

**Build-lock invariant:** `./run.sh` locks per worktree (repo-root `.dev/run-sh-build.lock.d`), through build→install→seed→`open`, then releases before the long-running wait. Parallel worktrees must not block each other. Two named-bundle builds in the *same* worktree still serialize (shared `Desktop/.build/`). Do not reuse the same explicit `OMI_APP_NAME` across worktrees — `/Applications/$APP_NAME.app` is machine-global and not cross-locked.

**Rules:**
- **NEVER use `OMI_APP_NAME` for local deploys** — do not create named bundles (`omi-<feature>` etc.); always deploy as "Omi Dev" over the existing install
- To connect agent-swift: `agent-swift connect --bundle-id com.omi.desktop-dev`
- **Jump to a screen without clicking:** the automation bridge auto-enables on non-prod bundles — `./scripts/omi-ctl navigate <screen>` (e.g. `rewind`, `memories`, `settings rewind`). See "Fast-Path for Local Iteration" in `e2e/SKILL.md`.
- Named/dev bundles default to the development Python and desktop backends unless
  an explicit launch URL overrides them. Before QA, run
  `./scripts/omi-ctl health`; its unauthenticated identity payload reports the
  resolved backend environment/URLs plus the agent-runtime handshake state.
  A protocol-compatible runtime that omits a required capability is rejected at
  startup; health never reports the expected protocol as if it were negotiated.
- Run `./scripts/agent-logic-harness.sh --cross-surface-smoke` before building a
  QA bundle. This is the compact Swift/Node contract gate; reserve full
  component suites and the live continuity gauntlet for PR readiness.

### Run Variants & Parallel Worktrees
- `./run.sh --yolo` — quick start against the dev backend, no local services. `OMI_SKIP_BACKEND=1` — app only, remote backend via `OMI_DESKTOP_API_URL`. `OMI_SKIP_TUNNEL=1` — no Cloudflare tunnel.
- **Parallel worktrees auto-isolate.** `scripts/dev-instance.sh` derives a unique instance from each linked git worktree, so `run.sh` (and `backend/scripts/dev-serve.sh`) pick per-worktree ports (desktop 10201+, Python 8080+, automation 47777+) and bundle name (`omi-<worktree>`). Kills are pidfile-scoped, and a taken port fails loud instead of clobbering. Override any of `OMI_INSTANCE` / `PORT` / `PYTHON_PORT` / `OMI_AUTOMATION_PORT` / `OMI_APP_NAME` to opt out.
- `Omi Dev` is the canonical shared development profile (reusable permissions, default auth seed source). To rebuild the real Omi Dev (`com.omi.desktop-dev`) from a linked worktree, pass the explicit override `OMI_APP_NAME="Omi Dev" ./run.sh` — auto-isolation would otherwise derive an `omi-<worktree>` named bundle, and the explicit name resolves back to the shared dev bundle id.
- Local Python backend (per-worktree port): `cd backend && ./scripts/dev-serve.sh`.

### Self-Testing the App (agents)

**Hard rule: you may not ask the user to verify a feature you have not actually exercised yourself.** Compiling, "looks correct from the code", or "scroll down to see it" are not verification. If the obvious path is blocked (permission, focus, missing tool), try a long sequence of alternatives before involving the user — extend the bridge with a new action, add a temporary in-process hook, search the web for a workaround, grant the missing permission yourself if you can, write a tiny standalone harness. Roughly: spend ten serious attempts across different approaches before you escalate. Asking the user is the last move, not the first.

Fast path (skips web login and sidebar click-through):

1. **Build + launch as "Omi Dev"** (see Local Deploys Always Target "Omi Dev" above): `./run.sh`. "Omi Dev" keeps its auth state between deploys, so once it's signed in, redeploys boot already-signed-in.
2. **Prefer the local bridge — it never touches the cursor.** It calls the app's real code in-process (no synthetic mouse events). Use it before reaching for `agent-swift click`/`cliclick`/computer-use. Auto-enables on non-prod bundles; run several at once via distinct `OMI_AUTOMATION_PORT` (default 47777). Navigation stays backgrounded unless `--show` is passed.
   - `./scripts/omi-ctl state` — app-state snapshot (selected tab, auth, onboarding).
   - `./scripts/omi-ctl navigate <screen> [settings-section]` — jump straight to a screen in ~150ms (`omi-ctl screens` lists targets).
   - `./scripts/omi-ctl actions` discovers semantic actions; `action <name> [k=v …]` runs them. Registrations require [effects](../../.github/agent-docs/desktop-automation-effects.md); `--read-only` rejects effectful actions.
   - `agent-swift` only for UI the bridge can't reach yet (`click` moves the cursor).
3. **Read logs to confirm behavior:** app + chat bridge in the exact path from
   `./scripts/omi-ctl log-path` (named dev bundles) or `/private/tmp/omi.log`
   (production); PostHog for remote events.
4. **Verify the actual behavior**, not just that the app launched — exercise the feature and check the logs/UI reflect the change.

### Default agent development loop

1. **Edit or diagnose:** run the smallest relevant unit/static harness. For repeated saves, start `./scripts/dev-feedback.py --watch swift '<filter>'` or `... rust '<filter>'`; do not launch the app only to obtain compile evidence.
2. **Swift/UI behavior:** redeploy "Omi Dev" with `./run.sh --yolo --fast-only` (never `OMI_APP_NAME`); add `--no-wait` only with a harness/external backend, then use the local bridge (`omi-ctl action`, `state`, or a semantic snapshot) to assert the changed behavior.
3. **Package boundary:** use `./run.sh --full` only for the first launch, resource/entitlement/package/runtime input changes, or when `--fast-only` reports an expected fingerprint mismatch.
4. **QA, commit, and PR readiness:** run `./scripts/omi-macos-dev doctor`, exercise the real user-facing path, then run the appropriate full component/PR contract.

`omi-macos-dev` defaults to bounded JSON summaries so an agent can safely inspect a busy machine. Pass `--verbose` to the specific command for path-level records (for example, `clean plan --verbose`); cleanup always requires the exact current plan hash. The normal 14-day retention window can be deliberately bypassed with `--older-than 0` only when the operator has explicitly approved immediate cleanup.

Never ask a user to test an unexercised path. A fast named-bundle launch plus a semantic bridge assertion is valid inner-loop evidence; a clean full bundle is release/QA evidence.

### After Implementing Changes

- `xcrun swift build` is for **compile checks only** — it does NOT start the backend
- To actually test, ALWAYS use `./run.sh --yolo` (deploys as "Omi Dev" against the hosted backends)
- Voice-path verification means a natural authenticated PTT turn — signed-out, forced-transcript, or reducer-only runs do not count; provider mint or payload changes must also show the deploy-inline provider probe.
- **When the user says "test it"**, use the `test-local` skill to build, run, and verify via macOS automation

### macOS Version Compatibility
- The deployment floor is `.macOS("14.0")` in `Desktop/Package.swift`. Every change must work on every supported macOS version from that floor up.
- Never call an API newer than the floor unguarded: wrap it in `if #available(macOS XX, *)` **and give the `else` branch a working fallback** (degrade the feature, don't blank it). Example: System Audio capture gates on `#available(macOS 14.4, *)` and hides cleanly below it.
- Version-dependent system facts (renamed apps, moved paths, changed defaults) get an explicit mapping with the old value still handled — stored user data may predate the change (example: `AppIconCache.renamedApps` maps "System Preferences" → "System Settings").
- Raising the deployment floor or dropping a fallback is a product decision — never do it as a side effect of another change.

### Open-Source Merge Hygiene
- Before starting and before committing, `git fetch origin && git rebase origin/main` (or merge) — other contributors land changes continuously; never review your diff against a stale base.
- Keep diffs surgical: touch only lines your change needs. No drive-by reformatting, renames, or import reshuffles in files others may have in-flight PRs against.
- After rebasing onto new upstream work, re-run the test suites for every file you touched **and** every file the rebase brought in that overlaps your change; a clean build alone is not revision.
- If your change modifies shared surfaces (Theme tokens, `SettingsSection`, bridge actions, INV-* contract files), grep for all usages — including tests and e2e flows — and update them in the same commit so concurrent contributors inherit a consistent tree.

### Agent Logic Harness
When touching desktop agent runtime, floating agent pills, realtime hub, PTT, or `pi-mono-extension`, run the focused harness before broader checks:
```bash
cd desktop/macos && ./scripts/agent-logic-harness.sh
```
It is self-driving for agents: it runs the risky Swift lifecycle/state tests, focused agent runtime tests, exact `pi-mono-extension` package tests, and prints per-step runtime. Use `--swift-only`, `--node-only`, or `--skip-install` only when narrowing a failure.

### Chat Continuity Write-Path (INV-6)

Main Chat, Home chat, and floating/notch chat are one timeline over one `ChatProvider` (`historyChatProvider`). Kernel `main_chat` turns are the durable source of truth; journal acceptance publishes the immediate pending projection, and **UI must never append a pre-journal turn**. No second durable transcript store, no `ChatProvider()` besides `mainInstance` for speculative warm, never dedupe turns by assistant/user text, and no new free-text agent identity formats.

The full contract (apply gate, idempotency keys, structured identity, derived pill cache, snapshot aliases, resources-on-message, preview text, forbidden dual-write patterns), the continuity PR definition of done, and the gauntlet gate policy live in [`docs/chat-continuity-write-path.md`](docs/chat-continuity-write-path.md). A PR touching chat write-path, kernel projection, floating viewport, agent timeline identity/open, or pill projection is incomplete without them: hermetic behavioral tests, `./scripts/agent-logic-harness.sh` green, and — for write-path/cross-surface changes — the named-bundle continuity gauntlet with evidence noted in the PR.

### Verifying UI Changes (agent-swift)

Verify Swift UI changes programmatically with [agent-swift](https://github.com/beastoin/agent-swift) (Accessibility-API CLI): setup, command reference, and key rules in [`docs/agent-swift-ui-verification.md`](docs/agent-swift-ui-verification.md). Never automate prod bundles.

### Changelog Entries

After completing a desktop task with user-visible impact, add one fragment file under `desktop/macos/changelog/unreleased/`. Format, automation, and guidelines: [`changelog/README.md`](changelog/README.md).

- Write from the user's perspective ("Fixed X", "Added Y"), one sentence, no period, unique kebab-case filename; commit the fragment with your other changes (same commit is fine)
- Internal-only **production** edits (dead-code deletion, refactors in `Sources/`) need an in-repo marker, not the `no-changelog-needed` PR label — that label is invisible after merge and reddens main. Add `{"kind": "none"}` under `desktop/macos/changelog/unreleased/` instead
- Do not edit `CHANGELOG.json` by hand; release automation regenerates it

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
