# Slop audit — 2026-09-02

Scope: the fork's delta from upstream, `git diff upstream/main -- app desktop omi`
(HEAD `ef409d8658`, merge base is upstream's tip `d1e83d90b0`, so the fork is a
strict superset). Repo tooling (`.github/`, `scripts/`, root `AGENTS.md`, `docs/`)
reviewed for drift against those areas. `backend/` skipped (byte-exact upstream
mirror). Read-only; nothing was changed. Purple, the "Omi Dev in place" rule, the
deleted backend auto-deploy workflows, the 3.0.25 firmware pin, the Haiku
ModelQoS defaults, and the agent subprocess env hardening (PiMonoWiringTests) are
deliberate and are not findings.

Overall: the app and firmware deltas are in good shape (small, commented, tested).
The real problem is on desktop: the 2026-08-01 upstream sync (PR #100) resolved
several upstream-rewritten files by taking upstream's version wholesale, which
silently dropped every production call site of six fork features. The fork-only
helper files, their unit tests, their e2e `covers:` entries, and their changelog
fragments all survived, so the tree looks like the features still exist and
`scripts/fork-feature-audit.sh` reports "ok" for them. Section A is that story;
everything else is small.

Severity legend: cosmetic < maintainability < correctness-risk.

---

## Remediation status (2026-09-03)

- PR #110: A1 orphans with no caller ever (`LocalSessionUploader`, `TranscriptionService` channel surface, `isLocalAIRuntimeReady`, `connectionFailureGuidance`) and their tests.
- PR #111: A1 re-wired idea capture, PTT floating-bar reveal/hide, and CoreAudio pre-warm.
- PR #112: A1 app-editing helpers, A2, B6, E1 (Q5: settings-level disable is the mechanism), E2 (Q4: the `run.sh --yolo` pair), plus the Omi Dev smoke script node path.
- Batch 2 (this PR): A3, B1, B2, B4, B5, B7 (`firebase_options_local.dart` only; the other three are re-wrapped by the pinned formatter either way), B8 (label only), C2 (case deleted), C3, C4, C5, C6, C7, C8, C9, C10, D1, D2, E3, E4, E5, E7.
- E6 landed on `main` in `644094a50c`.
- Batch 3 (owner calls, decided 2026-09-03): B3/Q3 (sync pre-load removed; the async path loads the same cache first), B9 (switch restyled), Q6 (legacy keychain migration retired), Q7 (`deep-review-2026-06-09.md` and `slop-audit-2026-07-02.md` deleted; `code-review-2026-08-19.md` keeps its two open items; the `superpowers/` design notes are not remediation records and stay), and the `web/` half of B8 (moved to `web/frontend/src/__tests__/hosted-api-defaults.test.mjs`).
- Still open: B10 (policy: normalize only on lines already being edited) and Q2 (unanswered).

## Status of the 2026-08-20 findings

| ID | Status |
|---|---|
| A1 auto-release / auto-deploy workflows back in `.github/workflows/` | **Open** (4 files, byte-identical to upstream; snapshots in `disabled-workflows/` still stale) |
| A2 Backend-Rust cutover drift | **Open** (`ARCHITECTURE.md` 12 "Rust" mentions, `AGENTS.md:55,259,272,290,308`, `release.sh:83,200`, `Backend-Rust/.env.example`, three `docs/developer/*.mdx`) |
| A3 dead `agent/src/mcp-servers.ts` | **Open** |
| B1 TranscriptionService multi-channel surface | **Open**, folded into A1 below (never had a caller) |
| B2 `APIError.invalidURL` never thrown | **Open** (case now carries a `String`; still zero construction sites) |
| B3 routed-summary wedge | tracked in `docs/code-review-2026-08-19.md` Open 1 |
| B4 duplicate `everConnected.insert` | **Open** (`OmiBleManager.swift:684`) |
| B5 `bleController` optional wrapper | **Open** (`AppDelegate.swift:174-175`) |
| C1 disabled-workflows README list incomplete | **Open** (still missing `desktop_promote_prod.yml`, `runtime_image_contracts.yml`) |
| C2 signing recipe in three places | **Open** |
| D3 `stopStreamDeviceRecording` `_isPaused` question | **Resolved**: the fork now leaves `_isPaused` alone, with a comment and a regression test |

---

## A. Post-sync structural findings (highest value)

### A1. QUESTION — sync PR #100 dropped every production caller of six desktop fork features; the orphans still pass the fork-feature audit
Severity: correctness-risk (silent feature regression) for the re-wire decision;
maintainability for the orphan code if the features are abandoned. Category: sync
orphan / dead code / test slop / doc drift.

At `73d62f635a` (2026-07-02, the last slop-audit remediation) each of these had a
caller in `Desktop/Sources`. At `9bd169ef6f` (the parent of the 2026-08-29 sync)
none did. `git log -m --first-parent -S` pins every loss to the merge commit
`6e66d06ee4` (PR #100, `codex/upstream-sync-20260801`): upstream rewrote
`AppState.swift`, `SidebarView.swift`, `PushToTalkManager.swift`, `AppsPage.swift`,
`OnboardingVoiceShortcutStepView.swift`, `SettingsContentView+General.swift`, and
`OmiApp.swift`, and the merge took upstream's side.

What is now dead (definition, former caller, what the user lost):

| Orphan | Defined at | Former caller (Jul 2) | Effect today |
|---|---|---|---|
| `IdeaCaptureToast` (210 lines) | `Desktop/Sources/IdeaCaptureToast.swift` | `AppState.swift` (9 refs) | Desktop idea-capture confirmation toast never shows |
| `IdeaCaptureSidebarAction`, `DesktopRecordingControlCopy` | `MainWindow/RecordingControlCopy.swift` | `SidebarView.swift` (11), `SettingsContentView+General.swift` (6), `SettingsSidebar.swift`, `OmiApp.swift`, `AppState.swift` | Sidebar "Capture Idea" button and the shared recording-control copy are gone; desktop idea capture has no UI entry point |
| `hideTemporarily()` `:3462`, `showForVoiceSession()` `:3470` | `FloatingControlBar/FloatingControlBarWindow.swift` | `PushToTalkManager.swift`, `OnboardingVoiceShortcutStepView.swift` | `PushToTalkManager.swift:555` is back to upstream's `FloatingControlBarManager.shared.show()`, so the fix in `69c7537684` / `a5b295a9f5` ("PTT chord press permanently re-enables the floating bar") is reverted in behavior |
| `AudioCaptureService.warmupCoreAudio()` `:180` | `Desktop/Sources/AudioCaptureService.swift` | `PushToTalkManager.swift` | CoreAudio HAL pre-warm on PTT no longer runs |
| `AppUpdateRequest` `:171`, `updateApp` `:439`, `multipartForm` `:462` | `Services/APIClient/APIClient+Apps.swift` | `MainWindow/Pages/AppsPage.swift` (app edit sheet) | Desktop app editing is gone; upstream's `AppsPage` has no edit path |
| `BrowserExtensionSetup.isLocalAIRuntimeReady` `:623` | `Desktop/Sources/BrowserExtensionSetup.swift` | `Chat/AgentRuntimeProcess.swift` (dropped by PR #81 remediation, then the file rewrite) | Readiness probe never consulted |
| `BrowserExtensionSetup.connectionFailureGuidance` `:582-620`, `ConnectionFailureGuidance` `:35` | same | none, ever (test-only from birth) | pure test fixture |
| `LocalSessionUploader` (79 lines) | `Desktop/Sources/LocalSessionUploader.swift` | none since before Jul 2 (callers from `b76fc84cfb`/`d335968116` lost in an earlier sync) | **Reinvented upstream**: `ConversationFinalizationService.swift:252` is upstream's native `createConversationFromSegments` path for on-device sessions. Candidate to drop for upstream's |
| `TranscriptionService.AudioChannel` `:29`, `configuredChannels` `:176`, `channels:` init `:202-209`, `sendAudio(_:channel:)` `:365`, `framedAudioPayload` `:370` | `Desktop/Sources/TranscriptionService.swift` | none, ever | staging that never landed (prior B1) |

Collateral that keeps the corpse looking alive:

- Tests that only exercise orphans: `Tests/IdeaCaptureSidebarActionTests.swift`,
  `Tests/IdeaCaptureToastHitRectTests.swift`, `Tests/TranscriptionServiceChannelTests.swift`,
  `Tests/FloatingControlBarManagerTests.swift:28,35` (2 of 4 tests),
  `Tests/BrowserExtensionSetupTests.swift:38-75` (3 of 6 tests),
  `Tests/APIClientRoutingTests.swift:855-889` (`testUpdateAppRoutesMultipartPatchToPython`).
- e2e `covers:` entries pointing at dead files: `e2e/flows/audio-recording.yaml:7`
  (`RecordingControlCopy.swift`), `e2e/flows/quick-note.yaml:7` (`IdeaCaptureToast.swift`),
  `e2e/flows/recording-finalization.yaml:7` (`LocalSessionUploader.swift`).
- Unreleased changelog fragments describing dead code that will ship in the next
  fork release notes: `changelog/unreleased/20260708-idea-toast-tap-margin.json`,
  `changelog/unreleased/20260708-recording-label-ellipsis.json`.
- `scripts/fork-feature-audit.sh:1973` (`check IdeaCapture desktop/macos/Desktop/Sources`)
  and `:1976` (`check AudioChannel ...`) grep for symbol presence in any file, so
  the orphan definitions satisfy them. The audit printed "ok: desktop idea capture
  (2 files)" for a feature with no UI. Ran it during this audit: all checks pass.
- `docs/developer/upstream-sync-and-backend-policy.mdx:64-69` still describes
  desktop idea capture as shipped.

Proposed change (owner decision, listed under Questions): for each row, either
re-wire the caller into upstream's rewritten file (a small, localized edit per
feature) or delete the orphan plus its tests, `covers:` lines, and changelog
fragments. Deleting is behavior-neutral today (nothing reaches the code);
re-wiring restores the fork's intended behavior. Independently of that choice,
`fork-feature-audit.sh` should assert on a production call site outside the
defining file (e.g. `grep -l IdeaCaptureToast.shared Desktop/Sources --exclude=IdeaCaptureToast.swift`)
so the next sync cannot pass it with a dead file.

### A2. Backend-Rust cutover drift (carried from 2026-08-20 A2, unchanged)
Severity: maintainability. Files and lines as listed in the status table above.
Nothing has moved since the last report; `desktop/macos/ARCHITECTURE.md` still
documents a "Swift To Rust Boundary" and `Backend-Rust/src/routes/` that do not exist.

### A3. Dead duplicate MCP server builder (carried from 2026-08-20 A3, unchanged)
Severity: maintainability. `desktop/macos/agent/src/mcp-servers.ts` is still
imported only by `agent/tests/browser-extension-config.test.ts`; `index.ts` still
has its own diverged `buildMcpServers`.

---

## B. app/ (Flutter + iOS native)

### B1. `bleController` optional wrapper and stray indentation (carried B5)
- `app/ios/Runner/AppDelegate.swift:174-175`: `let bleController: FlutterViewController? = controller` then `if let messenger = bleController?.binaryMessenger` on a non-optional parameter; the sibling blocks at `:183-184` and `:193-194` were converted to `do { let messenger = controller.binaryMessenger ... }`.
- `:166` (`flutterWatchAPI = ...`, 22-space indent) and `:208` (`methodChannel = ...`, 8-space indent) carry stray indentation from the same edit.
- Category: defensive cruft / convention. Severity: cosmetic. Proposed: mirror the `do { let messenger = controller.binaryMessenger }` shape; re-indent the two lines. Cannot change behavior (the guard can never fail).

### B2. "Already connected, re-discover services" logic duplicated in two places (carried B4, widened)
- `app/ios/Runner/Ble/OmiBleManager.swift:163-177` (`connectPeripheral`) and `:688-697` (`willRestoreState`) both set the delegate, insert into `everConnected`, seed `connectionStartTimes`, and call `discoverServices(nil)`, with near-identical comments. `:684` and `:691` insert the same uuid twice in one iteration (the original B4).
- Category: duplicated logic. Severity: maintainability. Proposed: one private `rediscoverServices(of peripheral:, uuid:)` helper called from both sites; drop the inner insert. Behavior-neutral.

### B3. `loadCachedRoutedSummary()` duplicates the first half of `loadOrGenerateRoutedSummary()`
- `app/lib/pages/conversation_detail/conversation_detail_provider.dart:461-497` re-implements config load, profile selection, prompt hash, and cache-freshness check that `loadOrGenerateRoutedSummary` (`:499-537`) performs again immediately; the only call site is `:334`, one line above `:335 unawaited(loadOrGenerateRoutedSummary())`.
- Category: duplicated logic. Severity: maintainability. The synchronous pre-load exists so the cached overlay is present before the first build; removing it would let one frame render without the overlay before the async path calls `notifyListeners`. Listed under Questions (Q3) rather than as a plain removal.

### B4. Redundant fall-through return after a catch that returns the same value
- `app/lib/services/frontend_template_router.dart:318-322`: `catch (_) { return defaults(); }` followed by `return defaults();`. The `if (decoded is Map)` branch is the only other path.
- Category: defensive cruft. Severity: cosmetic. Proposed: `return decoded is Map<String, dynamic> ? fromJson(decoded) : defaults();` inside the try, single `catch` return.

### B5. `debugPrint` in a file the fork otherwise leaves on `Logger`
- `app/lib/pages/phone_calls/phone_setup_verify_page.dart:90` `debugPrint('Phone verification check failed: $e')`; every other fork-added log line in `app/lib` uses `Logger.debug` (the fork even replaced a `debugPrint` with `Logger.debug` in `capture_controller.dart:1062`).
- Category: convention drift / stray debug logging. Severity: cosmetic. Proposed: `Logger.debug`.

### B6. `probeAccess` is dead on both sides of the Apple Health bridge
- `app/lib/services/integrations/apple_health_service.dart:48-60` `Future<bool> probeAccess()` has no caller since the fork removed the only one (`:181-184`, the "treat a completed prompt as connected" change). The native handler `app/ios/Runner/AppleHealthService.swift:53-54` (`case "probeAccess"`) and `:101` (`probeAccess(result:)`, 40 lines) are only reachable through that channel call.
- Category: dead code. Severity: maintainability. Proposed: delete the Dart method and the Swift case + function. Behavior-neutral.

### B7. Whitespace-only divergences from upstream
- `app/lib/pages/onboarding/primary_language/primary_language_widget.dart:197-199`, `app/lib/pages/settings/import_history_page.dart:233-234`, `app/lib/pages/settings/transcription_settings_page.dart:1942-1943` are byte-identical to upstream after stripping whitespace (re-wraps only). `app/lib/firebase_options_local.dart:22-24` is a re-wrap plus a trailing comma.
- Category: convention drift / merge surface. Severity: cosmetic. Proposed: `git checkout upstream/main -- <file>` for the three pure re-wraps; the fourth if the trailing comma is not load-bearing. Zero behavior change; removes four files from every future sync diff.

### B8. Source-string tripwire test without a static-check label, reaching into `web/`
- `app/test/unit/based_hardware_endpoint_defaults_test.dart:47-118` asserts on source text of five app files and seven `../web/frontend/...` files. The fork's other static checkers (`app/ios/test/*.rb`, desktop `omi-test-quality: source-inspection` comments) are labelled as such; this one is not, and it is the only app test that reads outside `app/`.
- Category: test slop (unlabelled static tripwire). Severity: cosmetic. Proposed: add a `// Static checker.` header like the Ruby tests; consider moving the `web/` assertions to a web-side check so `app/test.sh` does not depend on `web/` layout.

### B9. iOS-blue switch in a fork settings row
- `app/lib/pages/settings/task_integrations_page.dart:511` `activeThumbColor: const Color(0xFF007AFF)`; the fork's other new switches (`frontend_template_routing_settings_page.dart:2025-2028,2037-2040`) use the app's white-track / black-thumb style.
- Category: convention drift. Severity: cosmetic. Proposed: match the routing page's switch styling (visual-only; confirm before changing).

### B10. Em dashes in fork-authored comments
- 7 added comment lines in `app/`, 13 in `desktop/`, 1 in `omi/` contain `—` (e.g. `device_settings.dart:1709`, `OmiBleManager.swift:168,690`, `capture_controller.dart:2113`, `action_items_provider.dart:837`, `IdeaCaptureToast.swift:7,26,28`). Existing policy (2026-07-02 X1): normalize only on lines already being edited.
- Category: style. Severity: cosmetic. No standalone change proposed.

---

## C. desktop/ (Swift + agent TS + scripts)

### C1. See A1, A2, A3.

### C2. `APIError.invalidURL(String)` still has no construction site (carried B2)
- `desktop/macos/Desktop/Sources/Services/OmiHTTPTransport.swift:307` (case), `:335` (description arm); mapping arms added at `FloatingControlBar/RealtimeHubSessionPolicies.swift:785` and `MainWindow/Components/UserFacingErrorPresentation.swift:83`. The two fork guards that would use it (`APIClient.swift:792` `setConversationVisibility`, `APIClient+Apps.swift:473` `multipartForm`) throw `.invalidResponse`.
- Category: dead code. Severity: cosmetic. Proposed: delete the case and its three arms (zero-risk), or throw it from the two guards (changes an error string on an unreachable-in-practice path; owner's pick).

### C3. Half-finished `DefaultsKey` migration for the browser-extension keys
- `DefaultsKey.swift:114-117` adds `.playwrightExtensionToken`, used only by `SettingsContentView+Advanced.swift:395`. The literal `"playwrightExtensionToken"` remains at `SettingsPage.swift:673,683`, `BrowserExtensionSetup.swift:727`, `AuthService.swift:2623`. The new `"playwrightExtensionVerified"` key (`SettingsPage.swift:416,684`, `BrowserExtensionSetup.swift:728,771,774,782`) has no `DefaultsKey` at all.
- Category: convention drift / partial abstraction. Severity: cosmetic. Proposed: either add both keys to `DefaultsKey` and use them at every site, or drop the one-use enum case. Behavior-neutral.

### C4. Trivial wrapper property
- `desktop/macos/Desktop/Sources/MainWindow/Pages/SettingsPage.swift:643-645` `var browserExtensionStatusText: String { browserExtensionStatus.text }`, one call site (`SettingsContentView+FloatingBarAndChat.swift:606`).
- Category: premature abstraction. Severity: cosmetic. Proposed: inline `browserExtensionStatus.text`.

### C5. Literal `"auth_userId"` where `DefaultsKey.authUserId` exists
- `desktop/macos/Desktop/Sources/Rewind/UI/RewindViewModel.swift:275` (fork edit) reads `UserDefaults.standard.string(forKey: "auth_userId")`; `DefaultsKey.swift:6` says the enum exists precisely because that literal "appeared inline ~18 times".
- Category: convention drift. Severity: cosmetic. Proposed: `forKey: .authUserId`.

### C6. Constant `skippedForBattery = false` threaded through two identical blocks
- `desktop/macos/Desktop/Sources/Rewind/Services/RewindIndexer.swift:284-286` and `:415-417` declare `let skippedForBattery = false` with the same three-line "Legacy flag" comment, then pass it to `Screenshot(...)` and `textSource(ocrText:skippedForBattery:)` (`:226-234`), whose `skippedForBattery` branch is therefore unreachable from these callers.
- Category: dead parameter / duplicated comment. Severity: cosmetic. Proposed: drop the local and the `textSource` parameter, pass `skippedForBattery: false` inline (or rely on the `Screenshot` default), keep one comment. Behavior-neutral.

### C7. Two idioms for the same AX type-check fix
- `ScreenCaptureService.swift:895,928,943` uses `unsafeDowncast(_, to:)` after `CFGetTypeID` guards; `ProactiveAssistants/Services/OverlayService.swift:148,160,177` (same fork fix, same shape) uses `as!` after the same guards.
- Category: convention drift. Severity: cosmetic. Proposed: pick one (the `as!` form reads more like the surrounding upstream code).

### C8. Hedgy wording in a tool description sent to the model
- `desktop/macos/agent/src/omi-tools-http.ts:78` "...distinguish timer captures, future event captures, OCR text..." Only `timer` is ever written today (`CaptureTrigger` defaults; no `contextSwitch`/`manual`/`replay` producer in Sources).
- Category: misleading doc. Severity: cosmetic. Proposed: describe what exists ("timer captures; textSource distinguishes OCR, accessibility, hybrid, deferred").

### C9. Merged bullets in the fork-edited AGENTS section
- `desktop/macos/AGENTS.md:258` "- To connect agent-swift: `agent-swift connect --bundle-id com.omi.desktop-dev`- **Jump to a screen without clicking:** ..." lost its newline in the fork edit.
- Category: doc formatting. Severity: cosmetic. Proposed: split the bullet.

### C10. "release.sh mirrors run.sh; keep in sync" stated three times
- `desktop/macos/RELEASE.md:55-56`, `desktop/macos/AGENTS.md:76-77`, `desktop/macos/release.sh:9-10`.
- Category: doc duplication. Severity: cosmetic. Proposed: keep it in `release.sh` (where the person editing it is) and one doc.

---

## D. omi/ (firmware)

### D1. `omi/AGENTS.md:8` says the pre-commit hook is "symlinked into `.git/hooks/pre-commit`"
- It is a six-line exec wrapper written by `make setup`, not a symlink. The advice that follows (`--no-verify`) is unaffected.
- Category: doc drift. Severity: cosmetic. Proposed: "installed as a wrapper by `make setup`".

### D2. Trailing bare `return;` in a void function
- `omi/firmware/omi/src/lib/core/button.c:338` (fork replaced the upstream `return 0;` compile error with `return;` at the end of `void check_button_level`).
- Category: cosmetic. Proposed: delete the line. Optional; the fix itself is correct.

Everything else in `omi/` (idea-capture hold, pause/haptic modes, `utils.h` macro
hygiene, `codec.c` `#elif/#error`, devkit sdcard/storage bounds, transport PHY and
semaphore fixes, storage drain priority) is deliberate, commented once, and
consistent with the file it sits in. No narration comments, no `printk` leftovers.

---

## E. Repo tooling and docs

### E1. Auto-release / auto-deploy workflows still live in `.github/workflows/` (carried A1)
- `desktop_auto_release.yml`, `desktop_codemagic_failure_recovery.yml`, `desktop_promote_prod.yml`, `gcp_backend_pusher_auto_deploy.yml` are present and byte-identical to upstream; `.github/disabled-workflows/README.md:8-18` lists nine files while the directory holds eleven (`desktop_promote_prod.yml`, `runtime_image_contracts.yml` unlisted). Severity: correctness-risk (latent). Owner decision, see Q5.

### E2. Two different "hosted dev endpoint" pairs in fork docs and scripts
- `.github/disabled-workflows/README.md:22-25` and `docs/README.md:1823` say local desktop builds use `desktop-backend-hhibjajaja-uc.a.run.app` + `api.omi.me`; `desktop/macos/release.sh:86-87` and `scripts/omi-dev-smoke.sh:38-41` pin the same pair.
- Upstream's unmodified `desktop/macos/run.sh:118-119` (`apply_yolo_env`) exports `desktop-backend-dt5lrfkkoa-uc.a.run.app` + `api.omiapi.com` for `./run.sh --yolo`, which the fork docs call the normal dev path.
- Category: doc drift. Severity: maintainability (an agent following the README will assert the wrong URL in `.env`; `omi-dev-smoke.sh` would fail against a `--yolo` build). Which pair is intended for `Omi Dev` is Q4.

### E3. Root `AGENTS.md:69` (fork-edited line) still tells agents to verify on "a named `omi-*` bundle"
- Contradicts `desktop/macos/AGENTS.md:257` ("NEVER use `OMI_APP_NAME` for local deploys") and the `feedback_deploy_as_omi_dev` rule. Upstream's `:68` and `:17` mention named bundles too but are upstream lines.
- Category: doc drift. Severity: maintainability. Proposed: "(desktop: `./run.sh`, deployed as Omi Dev)".

### E4. Committed settings backup
- `.claude/backups/settings.local.json.20260608-211740.backup.json`: a June permission-list snapshot (references the `omi-togglefix` named bundle). Nothing reads it.
- Category: dead file. Severity: cosmetic. Proposed: delete; add `.claude/backups/` to `.gitignore`.

### E5. Commented-out YAML check blocks
- `.github/checks-manifest.yaml:407-414` and `:427-433` keep the full body of two disabled checks as comments under a one-line policy note. The note is the useful part; the commented body is dead config that will conflict whenever upstream edits those blocks.
- Category: commented-out code. Severity: cosmetic. Proposed: keep the two-line "Fork policy" comment, drop the commented YAML.

### E6. `scripts/fork-feature-audit.sh` certifies presence, not wiring
- `:1957-1979`: every check is `grep -rl <symbol> <dir>`, which any orphaned definition satisfies (see A1). The script's own header promises "a merge that silently dropped one fails loudly here".
- Category: tautological check. Severity: maintainability. Proposed: per feature, grep for a call-site token in a file other than the definer (or run the feature's behavior test), e.g. `IdeaCaptureToast.shared` with `--exclude=IdeaCaptureToast.swift`.

### E7. iPhone signing recipe in three places (carried C2, unchanged)
- `app/docs/local-ios-standalone-install.md` (declared source of truth), `app/docs/adam-local-iphone-signing.md`, `app/README.md:94-160`. Severity: maintainability. Proposed: shrink the README section to a pointer.

---

## F. Questions (owner call; not counted as findings)

1. **Re-wire or delete the desktop features dropped by sync #100 (A1).** Per row:
   idea-capture toast + sidebar action (feature gone), PTT floating-bar
   persistence fix (behavior reverted to upstream), CoreAudio warmup (perf
   nicety gone), desktop app editing (feature gone), `isLocalAIRuntimeReady`
   (probe unused), `LocalSessionUploader` (superseded by upstream's
   `ConversationFinalizationService`; drop), `TranscriptionService` channel
   surface (never wired; drop unless the two-channel `/v4/listen` plan is live).
2. **`app/lib/pages/settings/profile.dart:593-628`** re-adds Payment Methods,
   Conversation Display, and Data Privacy rows that upstream moved to
   `developer.dart:480-499`. Intentional second entry point, or a leftover from
   before upstream's move?
3. **`loadCachedRoutedSummary` (B3):** is the one-frame flash acceptable if the
   sync pre-load is removed in favor of the single async path?
4. **Which hosted pair should `Omi Dev` use (E2):** `hhibjajaja` + `api.omi.me`
   (fork docs, release.sh, smoke script) or `dt5lrfkkoa` + `api.omiapi.com`
   (what `./run.sh --yolo` actually exports)? Whichever it is, one of the two
   sides needs an edit.
5. **Workflows (E1 / prior A1):** re-delete from `.github/workflows/` and refresh
   the `disabled-workflows/` snapshots, or declare the GitHub-UI disable the
   mechanism and update the docs and manifest comments to say so.
6. **`AuthService.migrateLegacyForkKeychainTokens` (`AuthService.swift:2115-2145`):**
   one-time migration off the pre-2026-07-08 layout; retire once every install has
   booted a post-July build.
7. **Dated working docs** (`.github/agent-docs/superpowers/*`, `docs/deep-review-2026-06-09.md`,
   `docs/slop-audit-2026-07-02.md`, `docs/code-review-2026-08-19.md` with open items):
   archive the fully remediated ones.

---

## Explicitly checked and clean

- No overlap between fork additions and upstream commits landed since
  `a16cd1415c` beyond `LocalSessionUploader` (noted in A1). Upstream's
  `action_item_batch_delete` handling is foreground-only; the fork's
  `main.dart:143` background branch complements it. `indexIsChanging` guard
  mirrors upstream's own `usage_page.dart`.
- App fork features (idea capture, template routing, Apple Reminders auto-export
  with backend mirror and rollback, native BLE listener-driven subscriptions,
  UIScene adoption, App Group identity, CV1 pause/haptic sync) read as
  deliberate, commented once, and tested; `capture_provider_test`,
  `native_ble_transport_test`, `conversation_detail_template_routing_prompt_gate_test`,
  `phone_setup_verify_page_test` assert real behavior.
- Desktop fork features that are still wired (Dock icon toggle, task auto-promote,
  Rewind privacy filter and window patterns, capture provenance columns, AppProvider
  `setApp`, RewindDatabase init retry and crash-marker fix, sqlite recovery via
  temp file, agent token file, AX type guards, subscription decoder hardening,
  duration formatting) have production callers and behavioral tests.
- `privacy.dart:41-49` schema-mismatch try/catch is a commented, intentional
  fail-open against the hosted backend, not error swallowing.
- Ruby static checkers under `app/ios/test/` are registered in
  `.github/checks-manifest.yaml:277-294` and labelled "Static checker".
- `fork-feature-audit.sh` firmware-version floor and the 3.0.25 pin are correct.
- `.github` fork tolerance patches (`check-deployment-concurrency.py` `absent`
  set, desktop-backend release policy, source admission, diff hygiene,
  lifecycle headers, `scripts/failure-class` inherited-definition filter,
  `scripts/pre-push` guards) remain keyed off genuinely absent workflows.

## Counts

| Area | Findings | Open questions |
|---|---|---|
| app/ | 10 (B1-B10) | 2 (Q2, Q3) |
| desktop/ | 12 (A1, A2, A3, C2-C10) | 2 (Q1, Q6) |
| omi/ | 2 (D1, D2) | 0 |
| repo tooling / docs | 7 (E1-E7) | 3 (Q4, Q5, Q7) |

By severity: correctness-risk 2 (A1 silent desktop feature regression, E1 latent
workflows; both gated on owner decisions); maintainability 11 (A2, A3, B2, B3,
B6, B8-partial, E2, E3, E6, E7, plus A1's orphan cleanup once decided);
cosmetic 18 (B1, B4, B5, B7, B8, B9, B10, C2-C10, D1, D2, E4, E5).
