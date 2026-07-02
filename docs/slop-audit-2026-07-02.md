# Slop Audit, 2026-07-02

Read-only audit of the fork's divergence from upstream BasedHardware/omi.

- Baseline: `git merge-base upstream/main HEAD` = `ad3b7e37e` (the July 1 sync point).
- Scope: 295 changed files under `app/`, `desktop/`, `omi/` after excluding generated
  files (`app_localizations_*.dart`, `*.g.dart`, ARB, lockfiles, assets). ~22.7k added lines.
- `backend/` untouched and unread, per fork policy.
- Upstream is already 86 commits ahead of the sync point; two next-sync collision watches
  are listed at the end.

Overall: the divergence is in good shape. The large feature diffs (idea-capture across
firmware/app/desktop, frontend template routing, desktop apps-page rework, automation
bridge hardening, auth.rs XSS fixes) read as deliberate, commented, and tested. No
committed debug prints, no commented-out code blocks, no new TODO/FIXME markers. The
findings below are mostly small.

Severity legend: cosmetic < maintainability < correctness-risk.

## Remediation status (2026-07-02, PR: slop-audit remediation)

- Fixed: A1-A7, D1, D2, F1, F3.
- No change by design: A8 (locale-stable prompt), F2 (extern decls; a new header
  would itself be divergence), F4 (upstream-shared macro quirk, harmless), X1
  (em dashes normalized only on lines already being edited).
- Found while verifying (not in the original audit, fixed in the same PR):
  a compile error in language_selection_dialog.dart from the sync merge, stale
  audio_wave_painter tests still asserting the old 0.005 repaint threshold, and
  two hard-secret-detector tests asserting forms the detector never matched.
  The detector itself was NOT changed; its two coverage gaps (bare "token=" not
  caught on mobile unlike desktop, "Authorization: bearer <x>" caught on neither
  platform) are documented in the test file and remain open questions.

---

## app/ (Flutter + iOS native)

### A1. Committed merge artifact
- **File:** `app/lib/providers/capture_provider.dart.orig`
- **Category:** dead code (leftover file)
- **Severity:** maintainability
- **Detail:** A 289-byte `.orig` merge artifact committed by the sync merge (`7245aecc6`).
  Unreferenced by anything.
- **Proposed:** Delete the file; consider adding `*.orig` to `.gitignore`.

### A2. Purple UI in a fork-only page
- **File:** `app/lib/pages/settings/frontend_template_routing_settings_page.dart:87,94,298,310,373,375`
- **Category:** convention violation (root AGENTS.md: "Never use purple")
- **Severity:** maintainability
- **Detail:** Fork-only settings page uses `Color(0xFF7C4DFF)` (deep purple) for check
  icons, switch active tracks, and the "Manage apps" row.
- **Proposed:** Swap to white/neutral accents per the repo rule. Visual-only change, so
  confirming before remediation; the rule itself is unambiguous.

### A3. Duplicate import in a test
- **File:** `app/test/providers/capture_provider_test.dart:12,14`
- **Category:** dead code
- **Severity:** cosmetic
- **Detail:** `bt_device.dart` is imported twice (line 14 was added by the fork while
  line 12 already existed). Triggers the analyzer's `duplicate_import` lint.
- **Proposed:** Remove line 14.

### A4. Round-trip preference tests assert the mock
- **Files:** `app/test/unit/idea_capture_preferences_test.dart`,
  `app/test/unit/apple_reminders_auto_export_preferences_test.dart`
- **Category:** test slop (low-value assertions)
- **Severity:** cosmetic
- **Detail:** Both tests set a SharedPreferences value and read it back through the mock,
  which mostly exercises `shared_preferences`' own mock. The default-value assertions
  (`false` / empty until opt-in) are the only part pinning real behavior.
- **Proposed:** Keep the default-value asserts, drop or merge the round-trip cases into a
  single preferences test file. Low priority.

### A5. README local-signing section repeats itself and duplicates AGENTS.md
- **File:** `app/README.md:104-110` (and the section above it)
- **Category:** doc duplication / drift risk
- **Severity:** maintainability
- **Detail:** Two consecutive paragraphs both point to
  `docs/local-ios-standalone-install.md` (one calls it the single source of truth, the
  next repeats the pointer for the same doc). The full recipe also lives in
  `app/AGENTS.md` ("Adam Local iPhone Signing"), making three copies to keep in sync.
- **Proposed:** Collapse the two pointer paragraphs into one. Optionally trim the README
  steps to a short pointer at the canonical doc.

### A6. Repeated state-reset block in routed-summary provider
- **File:** `app/lib/pages/conversation_detail/conversation_detail_provider.dart:513-537` (plus 429, 585, 606)
- **Category:** repetition
- **Severity:** cosmetic
- **Detail:** `loadOrGenerateRoutedSummary` repeats the same 3-4 line reset block
  (`routedSummary = null; routedSummaryLoading = false; routedSummaryError = X;
  notifyListeners()`) in five sequential guard branches.
- **Proposed:** Extract a private helper, e.g. `_setRoutedSummaryIdle({String? error})`.
  Behavior-neutral.

### A7. Stray inline tag and duplicated rationale comments (idea-capture)
- **File:** `app/lib/services/capture/capture_controller.dart:2007-2010, 872, ~1005`
- **Category:** narration/redundant comments
- **Severity:** cosmetic
- **Detail:** The `forceProcessingCurrentConversation` docstring ends with a stray
  `// idea-capture` tag inside the `///` comment. The "follow the firmware's explicit
  hold signal, never toggle, dropped packet can't invert it" rationale appears twice
  (buttonState 6/7 handler and `_onIdeaCaptureSignal` docstring).
- **Proposed:** Drop the stray tag; keep one copy of the rationale and point the other
  site at it.

### A8. Hand-rolled weekday names (note only)
- **File:** `app/lib/services/frontend_template_router.dart:283-302`
- **Category:** reimplemented stdlib
- **Severity:** cosmetic
- **Detail:** `_weekdayName` switch duplicates `intl`'s `DateFormat('EEEE')` (already a
  dependency). Plausibly deliberate: the prompt (and its hash) should stay locale-stable
  English. Changing it would alter prompt text and invalidate cached hashes.
- **Proposed:** No change. Noted so a future cleanup doesn't "fix" it and silently
  invalidate the routed-summary cache.

Clean notes for app/: the `task_integrations_page` context-across-await fixes,
`native_ble_transport` subscription rework, `action_items_provider` partial-rollback fix,
photo viewer/grid broken-image fallbacks, AppDelegate deep-link channel, and
`OmiBleManager` state-restoration rediscovery all read as real fixes with real tests.
`based_hardware_endpoint_defaults_test.dart` is a lint-as-test guardrail that reads
source files (including `../web/*`); it is intentional but will fail noisily if upstream
renames those files. Deleted upstream pages (paypal setup, daily summary settings, etc.)
leave no dangling imports.

---

## desktop/ (Swift + Rust + agent TS)

### D1. Node-runtime readiness probe duplicates the launcher's discovery, with a different list
- **File:** `desktop/macos/Desktop/Sources/BrowserExtensionSetup.swift:607-640`
- **Category:** duplicated logic / drift risk
- **Severity:** maintainability (borderline correctness-risk for the guidance text)
- **Detail:** Fork-added `isLocalAIRuntimeReady` reimplements node-binary and
  agent-script discovery that `AgentRuntimeProcess.findNodeBinary()` (the component that
  actually launches the runtime) already performs. The candidate lists differ: the probe
  checks `~/.hermes/node/bin/node` and cwd-relative paths; the launcher checks the
  bundled node, nvm versions, and `which node`. The probe can therefore claim the
  runtime is missing when the launcher would find it (or the reverse), producing wrong
  "Local AI runtime is missing" guidance in the connection-failure dialog.
- **Proposed:** Make the launcher's discovery reusable (static or shared helper) and have
  `isLocalAIRuntimeReady` call it. Only the guidance path changes.

### D2. Dock-icon card icon is purple
- **File:** `desktop/macos/Desktop/Sources/MainWindow/Pages/Settings/Sections/SettingsContentView+General.swift:270`
- **Category:** convention conflict
- **Severity:** cosmetic
- **Detail:** The fork-added Dock Icon settings card uses `OmiColors.purplePrimary`,
  matching every neighboring upstream card in the same file, but violating the fork's
  no-purple rule.
- **Question for Adam:** follow the surrounding upstream convention (leave it) or the
  fork rule (white/neutral, making this one card visually different from its neighbors)?

Clean notes for desktop/: the AppsPage rework's small state structs
(`AppsPageFilterState`, `AppCardPrimaryActionState`, `AppDetailPrimaryActionState`,
`AppDetailSummaryPreferenceAction`, `AppPromptDisplayItem`) are all referenced and
unit-tested, so they are not premature abstraction. AppState idea-capture, the custom
menu controls in OmiApp, DesktopAutomationBridge token+loopback hardening, `auth.rs`
callback-escaping (with adversarial tests), APIClient `makeURL`/multipart additions,
LocalSessionUploader, RewindPrivacyFilter (+tests), `mcp-servers.ts` extraction, and the
`prepare-node-resource.sh` script (+test script) are deliberate and documented. No debug
prints, no dead helpers found (removed ScreenCaptureService helpers were deleted along
with their callers).

---

## omi/ (firmware)

### F1. AGENTS.md references feature bits that do not exist
- **File:** `omi/AGENTS.md:31-33`
- **Category:** doc drift
- **Severity:** maintainability
- **Detail:** The feature-flag section says firmware "may advertise bits the app does not
  currently read, like recording-pause `1 << 10`" and mentions "gaps like a skipped
  `1 << 9`". `features.h` ends at `OMI_FEATURE_MIC_GAIN (1 << 8)`; no `1 << 9` or
  `1 << 10` exists anywhere in firmware or app. The recording-pause feature was shipped
  as haptic-characteristic modes, not a feature bit.
- **Proposed:** Rewrite the parenthetical to drop the invented example (the numbering
  contract point stands on its own).

### F2. Ad-hoc `extern` declarations for set_led_state
- **Files:** `omi/firmware/omi/src/haptic.c:26`, `omi/firmware/omi/src/lib/core/button.c:31`
- **Category:** consistency
- **Severity:** cosmetic
- **Detail:** Both fork additions declare `extern void set_led_state(void);` locally
  (definition in `main.c`). Upstream never declared it in a header either, so a new
  header would itself be divergence.
- **Proposed:** Leave as-is (minimal divergence wins); noted for completeness.

### F3. idea-capture comment density
- **Files:** `omi/firmware/omi/src/{haptic.c,lib/core/button.c,settings.c,lib/core/settings.h}`
- **Category:** narration comments
- **Severity:** cosmetic
- **Detail:** 14 `idea-capture:` tagged comments across 5 files. The tag itself is
  load-bearing (it is the documented grep anchor for merge preservation, per
  `docs/developer/upstream-sync-and-backend-policy.mdx`), but a few restate the code
  ("enter idea capture mode -> solid green LED + single buzz" above code doing exactly
  that; `settings.c:269` repeats the not-persisted note already in the `settings.h`
  docstring).
- **Proposed:** Trim the restating ones; keep the tag and the two genuinely non-obvious
  rationales (GATT-cache reasoning in `haptic.c`, firmware-drives-LED in `button.c`).
  Do not remove the `idea-capture` anchors themselves.

### F4. ASSERT_TRUE logs a value known to be falsy (question)
- **File:** `omi/firmware/omi/src/lib/core/utils.h` (ASSERT_TRUE)
- **Category:** carried-through quirk
- **Severity:** cosmetic
- **Detail:** The fork's (correct) do-while rewrite preserved upstream's quirk: the macro
  logs `_result` after `!_result` passed, so it always logs 0. Fixing it would touch an
  upstream-shared macro.
- **Question for Adam:** worth fixing locally, or leave to minimize divergence?

Clean notes for omi/: the devkit `sdcard.c`/`storage.c` changes are genuine bug fixes
(use-after-free ordering, bounds check, retry-same-chunk on failed notify). The
`settings.h` doxygen blocks match the file's existing style. The `omi/AGENTS.md` pointer
to `docs/developer/upstream-sync-and-backend-policy.mdx` is accurate.

---

## Cross-cutting

### X1. Em dashes in fork-authored comments and docs
- **Category:** style (CLAUDE.local.md: no em dashes in generated text)
- **Severity:** cosmetic
- **Detail:** Fork-authored comments use em dashes liberally (capture_controller,
  AppState, auth.rs comments, omi/AGENTS.md, etc.). The local rule governs newly
  generated text, so this is not a violation per se, but any future sweep could
  normalize opportunistically when touching a line anyway.
- **Proposed:** No dedicated pass; fix in passing only.

## Next-sync collision watch (not slop, act during the next upstream pull)

1. **GmailReaderService.swift**: upstream (commits `4d4ea3f52`, `823910dde`, post-sync)
   extracted shared `BrowserPythonRunner` + `BrowserGoogleSession` helpers covering
   exactly what the fork's `LockedDataBuffer`, `BrowserScriptPython`, async pipe reading,
   and `BrowserKeychainCache.keychainPassword` do, and deleted the code paths the fork
   modified. On the next sync, prefer upstream's abstractions and drop the fork helpers.
   This file will conflict.
2. **AppsPage.swift**: upstream also reworked it (Apple Notes connector, integration
   hardening). The fork's 973-line rework will need a careful manual merge; the fork's
   state structs have tests that should keep behavior pinned.

---

*Audit method: `git diff ad3b7e37e..HEAD` per area, full reads of new files, diff+context
reads of modified files, grep sweeps for debug prints / TODO markers / commented-out
code / purple / duplicate logic, and reference checks for deleted files and new
abstractions. No code was modified.*
