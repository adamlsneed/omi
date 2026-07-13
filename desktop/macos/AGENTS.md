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

### Product analytics integrity

- A desktop chat query starts after local concurrency/quota preflight and must
  emit exactly one terminal outcome: `completed`, `failed`, or `cancelled`.
  Intentional Stop and supersession are cancellations, never errors.
- Query latency ends when the final answer is visible. Persistence, title
  generation, and other post-answer work have their own reliability signals and
  must not inflate user-visible query duration.
- Product authority is independent from telemetry. Revoked or timed-out turns
  cannot apply late callbacks/results or persist a late response even if
  analytics is disabled or refactored.
- PostHog receives bounded dimensions and shape metadata only. Never send raw
  prompts, responses, notification/window titles, filesystem paths, or exception
  messages. Keep diagnostic detail in the private local log and Sentry.
- Production `QueryTracer` output is shape-only and stored under a `0700`
  directory in `0600` files. Full prompt/response/tool content is a deliberate
  non-production debugging capability only.

### Fallback / resilience telemetry
Provider/mode switches and fail-open paths must call `DesktopDiagnosticsManager.recordFallback(area:from:to:reason:outcome:)` (PostHog `desktop_health_event` / `fallback_triggered`) or Rust `fallback::record_fallback`. Same field contract as root `AGENTS.md` → Fallback / resilience telemetry. Do not invent new health-event enum cases or product “Recording Error” events for successful heals (`outcome=recovered`).

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
- `OmiSupport` — shared desktop runtime helpers (`Sources/OmiSupport/`, e.g.
  `DesktopLocalProfile` and `Dictionary(lastWriteWins:)`)

`Rewind/Core/` remains in the executable target for now — it still references main-app
types (`TaskActionItem`, `PowerMonitor`, etc.) and needs a shared-models carve-out first.

**Do not add new `.swift` files directly under `Desktop/Sources/`.** Place new
code in a feature directory (`Onboarding/`, `MainWindow/`, `Chat/`, etc.). CI
enforces this via `scripts/check-sources-root-layout.py`.

When carving out additional leaf modules, prefer bottom-up order (models and
storage before UI) and wire `import` + `public` on the extracted target's API.

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
  name or implementation string is not behavioral coverage.
- Source inspection is reserved for narrow forbidden-pattern or static wiring
  tripwires. New tripwires must carry a local reason:
  `// omi-test-quality: source-inspection -- static contract: <what cannot be expressed behaviorally>`.
  The tripwire supplements rather than replaces behavioral coverage.
- Do not add wall-clock sleeps to unit tests. Inject a `Clock`/sleeper, drive a
  callback/continuation, or await a deterministic state signal. An unavoidable
  real-scheduler integration wait needs
  `// omi-test-quality: wall-clock-wait -- <why injection cannot test this boundary>`.
- `python3 scripts/check_desktop_test_quality.py` ratchets both legacy
  source-inspection sites and wall-clock waits; its baselines may only decrease.

## Key Architecture Notes

### Authentication
- Firebase Auth with Apple/Google Sign-In
- Desktop apps should use backend OAuth flow: `/v1/auth/authorize`
- Apple Services ID: `me.omi.web` (shared across all apps)
- iOS apps use native Sign-In, Desktop uses backend OAuth + custom token
- Session death is owned by `AuthSessionCoordinator` (`INV-AUTH-1`); use `invalidateSession` for expired/revoked Firebase creds, not nuclear `signOut()`.

#### Session 401 vs BYOK/provider 401

| Failure class | Owner | Action on 401 after forced refresh |
|---------------|-------|-----------------------------------|
| Firebase session token (default API `Authorization`) | `AuthSessionCoordinator` | `invalidateSession` → Sign-in CTA |
| BYOK provider key on request | `CredentialHealthManager` | Suppress/mark provider unhealthy; **do not** invalidate Firebase session |
| Realtime/voice managed lane | `CredentialHealthManager` + hub UX | `requiresLogin` only when session mint fails after refresh |
| Background poll with `RequestAuthPolicy.sessionPreserving` | Caller | Throw `.unauthorized`; no session invalidation |
| `DesktopLocalProfile` harness | Auth emulator bootstrap | Re-bootstrap emulator session; no prod invalidation side effects |

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

**Build-lock invariant:** `./run.sh` locks per worktree (repo-root `.dev/run-sh-build.lock.d`), through build→install→seed→`open`, then releases before the long-running wait. Parallel worktrees must not block each other. Two named-bundle builds in the *same* worktree still serialize (shared `Desktop/.build/`). Do not reuse the same explicit `OMI_APP_NAME` across worktrees — `/Applications/$APP_NAME.app` is machine-global and not cross-locked.

**Rules:**
- **NEVER use `OMI_APP_NAME` for local deploys** — do not create named bundles (`omi-<feature>` etc.); always deploy as "Omi Dev" over the existing install
- To connect agent-swift: `agent-swift connect --bundle-id com.omi.desktop-dev`
- **Jump to a screen without clicking:** the automation bridge auto-enables on non-prod bundles — `./scripts/omi-ctl navigate <screen>` (e.g. `rewind`, `memories`, `settings rewind`). See "Fast-Path for Local Iteration" in `e2e/SKILL.md`.

### After Implementing Changes
- `xcrun swift build` is for **compile checks only** — it does NOT start the backend
- To actually test, ALWAYS use `./run.sh` (deploys as "Omi Dev") — it starts Rust backend + Cloudflare tunnel + Swift app together
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

### Chat Continuity Write-Path Contract (INV-6)

Invariant: Main Chat, Home chat, and floating/notch chat are one timeline over one
`ChatProvider` (`historyChatProvider`). Kernel `main_chat` turns are the durable
source of truth; journal acceptance publishes the immediate pending projection,
and UI must never append a pre-journal turn.

Rules (fail the PR if any break):
1. **Single provider + floating viewport** — floating presentation is chrome + a
   viewport cursor (`FloatingChatViewport` message ids / `clientTurnId`) over
   `ChatProvider.messages`. It must not own a second durable transcript array
   (`chatHistory` of `ChatMessage` copies is forbidden).
2. **Single `turn_recorded` UI apply gate** — only `KernelTurnProjection` on
   `ChatProvider.mainInstance` (`historyChatProvider`) may attach the runtime
   turn handler (one replaceable slot). Speculative warm and other surfaces must
   reuse `mainInstance`; never construct a second `ChatProvider()` that calls
   `attachClient` / `setTurnRecordedHandler` on the shared runtime.
3. **One idempotency key per logical turn** — call `recordJournalExchange` (or
   the corresponding kernel control RPC) with one opaque continuity key and
   await acceptance before binding a visible row. Direct-control spawn receipts
   already materialize their exchange; refresh that journal instead of issuing a
   second write. Never dedupe by assistant/user text.
4. **Kernel apply is idempotent** — `KernelTurnProjection` upserts only by the
   canonical turn ID published by ordered journal replay. Rejection must leave no
   visible row, and replay/acknowledgement must replace rather than append.
5. **Cross-surface agent identity is structured** — `agentSpawn` / `agentCompletion`
   content blocks (plus tool-block `spawnedAgentID` / sessionId / runId lines) are
   authoritative. Persist structured blocks through the kernel journal/outbox so
   they survive reload; kernel apply still materializes `agentCompletion` from
   bracket text for legacy rows. Legacy `[Background agent id=…]` bracket
   text remains dual-read only. Do not invent new free-text formats; extend the
   schema + tests together.
   Proactive notifications use continuity key `notification:<uuid>` (origin
   `proactive_notification`) and enter the notification-to-chat cache only after
   journal acceptance; do not reintroduce local timeline append paths.
6. **Pill cache is derived** — open-by-id hydrates from kernel (`listFloatingAgentPills`
   / `listAgentSessions` / `inspectAgentRun`) when the in-memory pill is missing;
   refresh-on-miss is a fast path only. Success = resolvable agent after hydrate.
   Do not keep a second durable pill store.
7. **Snapshots are aliases** — `automationFloatingChatSnapshot` ==
   `automationChatSnapshot` / `automationMainChatSnapshot` over the same messages;
   no surface-specific transcript filter.
8. **Resources live on the producing message** — artifacts attach to the
   `ChatMessage` that produced them (stage/promote keeps `resources` on that id).
   UI must not invent a standalone artifact-only turn. Floating/notch resource
   strips bind `message.displayResources` on viewport-derived messages only
   (never flatMap the whole provider timeline). Aggregate strips must filter
   with `ChatContinuityInvariants.resourcesBelongingToMessages` /
   `FloatingControlBarState.viewportDisplayResources`.
9. **Agent card/list preview = prompt/objective** — collapsed header / list
   subtitle uses `ChatContinuityInvariants.agentPreviewText(prompt:output:)`
   (prompt wins; output is expanded-body only). Do not put raw completion output
   in the one-line preview.
10. **Forbidden dual-write patterns** — never: construct `ChatProvider()` for
    speculative warm (use `ChatProvider.mainInstance`); add
    `addTurnRecordedHandler` / multi-handler append APIs; introduce
    `suppressNextRecordedTurn`; store `@Published var chatHistory` of
    `ChatMessage` copies on `FloatingControlBarState`.
11. **Tests** — continuity behavior changes require a hermetic behavioral test (call
   projection/provider APIs, assert message counts/IDs). Source-string greps for
   function names are not continuity coverage (forbidden-pattern tripwires are the
   exception). Live gauntlet/stress are gates, not substitutes for hermetic tests.

### Continuity PR Definition of Done (INV-6)

A PR that touches chat write-path, kernel projection, floating viewport, agent
timeline identity/open, or pill projection is incomplete until:

1. **Contract still true** — INV-6 rules above hold after the change (or are
   updated in the same PR with a matching behavioral test).
2. **Hermetic behavioral test** for the invariant touched (stage/promote,
   snapshot alias, structured identity, open-by-id hydrate, viewport derive /
   restore, resources-on-message, agent preview text). Not a source grep
   (except forbidden-pattern tripwires).
3. **`./scripts/agent-logic-harness.sh` green** (includes
   `KernelTurnRecordedProjectionTests`, `ChatTimelineContinuityTests`,
   `FloatingControlBarStateTests`, `RuntimeOwnerIdentityTests` in the Swift
   focus filter).
4. **Write-path / cross-surface changes:** run a named-bundle continuity
   gauntlet and note evidence in the PR:
   ```bash
   cd desktop/macos && OMI_APP_NAME=omi-gauntlet OMI_SKIP_TUNNEL=1 ./run.sh
   # run.sh seeds auth after install (UD tokens → app Keychain migrate). Manual reseed:
   # ./scripts/omi-auth-seed.sh com.omi.omi-gauntlet tmp/desktop-auth.json "/Applications/omi-gauntlet.app"
   ./scripts/agent-continuity-gauntlet.sh --suite continuity --bundle-id com.omi.omi-gauntlet
   ./scripts/check-gauntlet-evidence-at-head.sh
   ```
   CI only runs gauntlet `--self-check` (wiring). Live suite is a PR/RC gate,
   not PR CI. Do not assert exact assistant wording.
5. **Hermetic e2e** only if a bridge action/surface contract changed. Do not
   expand flow `covers:` lists as fake continuity coverage.
6. **No second message store** / no new free-text identity format / no
   `suppressNextRecordedTurn`-style dual-write bandage.
7. Changelog fragment only if user-visible.

### Gauntlet / stress gate policy

- **CI:** `agent-continuity-gauntlet.sh --self-check` only (via desktop-core /
  agent-logic harness). Never require live LLM in PR CI.
- **Continuity PRs / RC:** `--suite continuity` (typed + PTT + blind recall) on
  a named `omi-*` bundle after auth seed; `--suite all` for RC. Evidence under
  `.harness/agent-continuity-gauntlet/*/manifest.json` with matching git SHA.
- **Anti-flake:** clear owner/kernel surface before probes; per-run nonces;
  hard-fail on blind-recall / structural snapshot only; zero automatic retries
  on model wrongness.
- **Stress:** offline JSONL + forbidden terminal reasons remain the default
  gate; live bridge probes stay optional until continuity `terminal_reason`s
  exist in the taxonomy.

### Live gauntlet vs hermetic INV-6 coverage

Do not confuse these gates — a green live suite does **not** prove write-path
contract rules, and hermetic unit tests do **not** prove bridge/LLM continuity.

| Gate | What it covers | What it does **not** cover |
| --- | --- | --- |
| **Hermetic** (`agent-logic-harness.sh` Swift filter: `KernelTurnRecordedProjectionTests`, `ChatTimelineContinuityTests`, `FloatingControlBarStateTests`, `RuntimeOwnerIdentityTests`) | stage/promote same key → one message pair; floating snapshot aliases main; structured agent identity; open-by-id hydrate preference; floating viewport derive / SoT; resources on producing message; agent preview = prompt; owner-swap preserves Firebase tokens; forbidden dual-write tripwires | Live bridge auth, LLM tool use, PTT hub, race/busy policy under a real runtime |
| **Gauntlet `--self-check`** | Bridge action registration (incl. R3 `ask_main_chat_no_wait` / `main_chat_busy_state`), resilience suite wiring, hermetic contract test presence in harness filter | Any live turn |
| **Live `--suite continuity` / `agents` / `owner` / `prompts`** | Typed + PTT + blind recall, spawn/status, owner swap probe, prompt regressions on a named bundle | stage/promote single-writer, snapshot alias, hydrate preference, viewport SoT (those stay hermetic) |
| **Live `--suite resilience` (R1–R4)** | Cold bridge launch, warm reuse, bridge busy/race rejection (R3; requires real `is_sending`/`is_streaming` once, latch only extends the race window), subagent launch+status (R4) | INV-6 write-path unit invariants above |

`--self-check` fails if R3 race actions or the hermetic INV-6 test methods /
harness filter classes drift away.

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
