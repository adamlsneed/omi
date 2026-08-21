# Slop audit — 2026-08-20

Scope: the fork's divergence from upstream, `git diff upstream/main...HEAD`
(merge base `b284133c5f`), limited to `app/`, `desktop/`, `omi/`, `scripts/`,
`.github/`, and `docs/`. `backend/` skipped (byte-exact upstream mirror);
`web/` deprioritized. Audit is read-only; nothing was changed. Purple, the
"Omi Dev in place" rule, the deleted backend auto-deploy workflows, the 3.0.25
firmware pin, and the agent subprocess env hardening / PiMonoWiringTests were
treated as deliberate and are not findings.

Overall: the fork's feature code (idea-capture, frontend template routing,
CV1 BLE fixes, dock-icon setting, UIScene migration, Rewind provenance) is
carefully engineered and well tested. The real cruft is concentrated in
post-sync fallout: workflows and docs that the last three syncs made wrong,
plus a handful of dead-code stragglers.

---

## A. Post-sync structural findings (highest value)

### A1. QUESTION — upstream syncs reintroduced the auto-release / auto-deploy workflows the fork deletes
Severity: correctness-risk (currently latent). Category: reinvented-upstream / sync orphan.

The fork's documented mechanism for "never auto-release, never deploy
backends" is deleting these workflows from `.github/workflows/` and parking
snapshots in `.github/disabled-workflows/`. The 2026-08-01 sync (PR #100)
brought three of them back into `.github/workflows/`, byte-identical to
upstream, and they have survived two further syncs:

- `.github/workflows/desktop_auto_release.yml` — hourly `schedule` cron plus
  `workflow_dispatch`; dispatches Codemagic candidate builds.
- `.github/workflows/gcp_backend_pusher_auto_deploy.yml` — `push` to `main`
  on `backend/**` paths, which every sync merge touches.
- `.github/workflows/desktop_promote_prod.yml` — `workflow_dispatch` only.

Current live state (checked via `gh api repos/adamlsneed/omi/actions/workflows`):
`desktop_auto_release.yml` and `gcp_backend_pusher_auto_deploy.yml` are
`disabled_manually` in the GitHub UI, so nothing is firing today.
`desktop_promote_prod.yml` and `desktop_codemagic_failure_recovery.yml`
(triggers on `check_run: completed`) are `active`.

Why this is still a problem:
- The tree now contradicts every fork-side statement of the policy:
  `desktop/macos/AGENTS.md:57-59` ("Upstream's Codemagic/auto-release
  workflows were removed"), `.github/disabled-workflows/README.md`, and the
  fork comments in `.github/checks-manifest.yaml` (~line 437 "the fork
  deletes the auto-deploy workflows this contract requires to exist"; ~line
  460 "the auto-deploy workflow this budget audits is deleted" — no longer
  true for pusher).
- The GitHub-UI manual disable is an invisible second mechanism: it is not
  in the repo, a future agent auditing the tree cannot see it, and
  re-enabling is one click. The next sync will keep merging upstream changes
  into these live files.
- The `.github/disabled-workflows/` snapshots of the same three files are now
  stale (they differ from the active copies), so the directory no longer
  documents "what was removed."

Proposed change (needs owner decision because it changes CI behavior): pick
one mechanism. Either (a) re-delete the three from `.github/workflows/`
(restores the documented fork state; refresh or drop the disabled-workflows
snapshots at the same time), or (b) declare GitHub-level disable the new
mechanism and update `desktop/macos/AGENTS.md`, `.github/disabled-workflows/README.md`,
and the checks-manifest comments to say so. Also decide whether
`desktop_codemagic_failure_recovery.yml` should stay active on the fork.

### A2. Backend-Rust cutover drift — fork docs and files describe a component upstream deleted
Severity: maintainability (docs actively mislead). Category: doc drift / sync orphan.

Upstream completed the "Python desktop backend cutover" on 2026-07-26
(`2276b42ad7`) and deleted `desktop/macos/Backend-Rust/` entirely. That
reached the fork in the 2026-08-01 sync. Three weeks later the fork still
carries:

- `desktop/macos/Backend-Rust/.env.example` — fork-added, now the only file
  in the directory; documents env for a service with no source in the tree.
  Safe to delete; never read at runtime.
- `desktop/macos/ARCHITECTURE.md:9-10,20,30,44,84` — fork-authored (June 11);
  claims a "Swift To Rust Boundary", "Rust exposes Axum routes under
  `Backend-Rust/src/routes/`", and a local Rust backend. All stale.
- `desktop/macos/AGENTS.md:55,259,290,308` — fork edits that rewrote
  upstream's "Python" wording to "Rust" ("Swift app + Rust backend live
  here", "development Python and Rust backends", "local Rust backend log
  path", "starts Rust backend + Cloudflare tunnel"). Post-cutover these fork
  overrides are the wrong side; reverting toward upstream's wording also
  shrinks future merge conflicts.
- `docs/developer/repository-guide.mdx:31,61,77-93` — instructs
  `cp Backend-Rust/.env.example Backend-Rust/.env` and
  `cd Backend-Rust && cargo check`, both now impossible.
- `docs/developer/upstream-sync-and-backend-policy.mdx:59,114,158` —
  verification table row "Desktop Rust backend | cd desktop/macos/Backend-Rust
  && cargo check" now impossible.
- `docs/developer/desktop-ai-browser-and-tasks.mdx:20` — "desktop Rust
  backend service" naming for `OMI_DESKTOP_API_URL` is stale.
- `desktop/macos/release.sh:83,187,200` — `BACKEND_DIR="Backend-Rust"` is now
  only a vestigial fallback that greps `Backend-Rust/.env` for
  `FIREBASE_API_KEY`. QUESTION rather than recommendation: a gitignored
  `Backend-Rust/.env` may still exist on the release machine and be the
  live source of that key, so verify locally before removing the fallback.

Proposed change: delete the orphan `.env.example`, update the five docs, and
(after local verification) drop the release.sh fallback. Doc edits cannot
change runtime behavior.

### A3. Dead duplicate of the MCP server builder, tested instead of the real one
Severity: maintainability. Category: duplicated logic / test slop.

- `desktop/macos/agent/src/mcp-servers.ts` (fork-added, 74 lines) exports
  `buildMcpServers`, with a header comment saying it was "extracted from
  index.ts" for testability. It never was wired in: `index.ts:1379` defines
  its own private `buildMcpServers`, upstream's, which has since diverged —
  production gates Playwright behind `PLAYWRIGHT_MCP_ENABLED === "true"` and
  adds `OMI_ADAPTER_ID`, surface-kind, chat-first, and execution-role envs;
  the extracted copy has none of that and additionally honors a
  `PLAYWRIGHT_MCP_EXTENSION` alias production ignores.
- `desktop/macos/agent/tests/browser-extension-config.test.ts` is the only
  importer, so the vitest suite is asserting the behavior of a fossil, not
  the shipping wiring.

Proposed change: delete both files, or (if the extension-flag coverage is
worth keeping) export the real builder from `index.ts` behind a test seam and
point the test at it. Deleting cannot change runtime behavior; the module is
unreferenced by production code.

---

## B. Dead code

### B1. QUESTION — TranscriptionService multi-channel surface has no production callers
`desktop/macos/Desktop/Sources/TranscriptionService.swift:29-32` (AudioChannel
enum), `:171` (`configuredChannels`), `:197` (`channels:` init param),
`:238-239` (legacy convenience init forwarding), `:360-370`
(`sendAudio(_:channel:)`, `framedAudioPayload`).

Both production constructions (`AppState+Transcription.swift:103,1269`) use
the default `channels: 1`, and nothing calls the channel-framed send path.
Only `desktop/macos/Desktop/Tests/TranscriptionServiceChannelTests.swift`
exercises it (mock-only coverage of unused code). The fork's own
`docs/code-review-2026-08-19.md` already noted "no callers yet." Flagged as a
question because this looks like staging for separate mic/system-audio
streams to `/v4/listen`; if that plan is dead, remove the surface plus its
test. Removal would not change behavior today.

### B2. `APIError.invalidURL` is never thrown
`desktop/macos/Desktop/Sources/Services/OmiHTTPTransport.swift:307` (case) and
`:335` (errorDescription arm). Fork-added, zero construction sites — the one
guard it was presumably written for
(`desktop/macos/Desktop/Sources/APIClient.swift:714-720`,
`setConversationVisibility`) throws `.invalidResponse` instead. Either delete
the case (no behavior change) or use it at that guard (changes the error
description string on an unreachable-in-practice path — owner's pick;
deleting is the zero-risk option). Severity: cosmetic.

### B3. Already tracked: routed-summary dead guard and wedge
`app/lib/pages/conversation_detail/conversation_detail_provider.dart:239-244`.
The fork's own `docs/code-review-2026-08-19.md` (Open finding 1) documents
that the `previousConversationId != conv.id` clear never fires on the real
navigation path and that `loadOrGenerateRoutedSummary`'s finally-block can
wedge the spinner when switching conversations mid-request. This is a
behavior bug plus dead code, already tracked with a fix direction; listed
here only for cross-reference so it is not lost. Not re-counted as a new
finding.

### B4. Duplicate `everConnected.insert(uuid)` in BLE state restoration
`app/ios/Runner/Ble/OmiBleManager.swift:694` re-inserts a uuid already
inserted at `:684` in the same loop iteration (fork addition in the
restored-already-connected branch). Harmless set insert; drop the inner one.
Severity: cosmetic. No behavior change.

### B5. Pointless optional wrapper left by the UIScene migration
`app/ios/Runner/AppDelegate.swift:163-164` —
`let bleController: FlutterViewController? = controller` wraps the non-optional
parameter in an optional and then `if let`-unwraps it; the sibling blocks were
converted to plain `do { let messenger = controller.binaryMessenger ... }`.
Also `:155` carries stray deep indentation from the same edit. Severity:
cosmetic. Straightening this cannot change behavior (guard can never fail).

---

## C. Doc drift (smaller)

### C1. `.github/disabled-workflows/README.md` list is incomplete
`README.md:8-15` lists six workflows; the directory also holds
`desktop_promote_prod.yml` and `runtime_image_contracts.yml`. Fold this into
whatever resolution A1 gets (if the actives are re-deleted, refresh the
snapshots and the list together). Severity: cosmetic.

### C2. iPhone local-signing recipe is maintained in three places
- `app/docs/local-ios-standalone-install.md` (413 lines, self-declared
  "single source of truth"),
- `app/docs/adam-local-iphone-signing.md` (dense summary, created to satisfy
  the AGENTS.md size ratchet),
- `app/README.md:94-160` (a third, step-numbered retelling with the same
  team ID, device IDs, and caveats).

Three copies of the same cert/team/device constants will drift on the next
change. Proposed: shrink the `app/README.md` section to a short pointer at
the standalone-install doc (the ratchet doc already points there). Severity:
maintainability. No behavior change.

---

## D. Open questions (deliberate-looking; owner call, not findings)

1. **Legacy fork keychain token migration** —
   `desktop/macos/Desktop/Sources/AuthService.swift:2098-2146`
   (`migrateLegacyForkKeychainTokens`). One-time migration from the
   pre-2026-07-08 fork layout. Once every machine has booted a post-July
   build, this can be retired; removing it early would strand an unmigrated
   install at the login screen, so timing is the owner's call.
2. **Dated working docs in `docs/`** — `code-review-2026-08-19.md` (has open
   findings, clearly load-bearing), `deep-review-2026-06-09.md`,
   `slop-audit-2026-07-02.md`. Deliberate trackers; consider archiving the
   fully remediated ones so the docs root stays navigable.
3. **`stopStreamDeviceRecording` sets `_isPaused = false` right after
   requesting a device pause** (`app/lib/services/capture/capture_controller.dart`
   ~line 1914). The comment explains the intent (leave CV1 muted until the
   next explicit start without persisting an app-side mute), so treated as
   intentional; noted only because the sequence reads like a bug at first
   glance and might deserve one more sentence of comment.

---

## Explicitly checked and clean

- Firmware (`omi/`): idea-capture button/haptic/settings plumbing, devkit
  sdcard/storage bounds fixes, `utils.h` macro hygiene, codec `#elif`/#error —
  all deliberate, commented, and consistent. (The known open firmware issues
  are already tracked in `docs/code-review-2026-08-19.md`.)
- The fork's SQL CTE patch converged byte-identically with upstream's fix
  during the 2026-08-20 sync (`RewindDatabase+Embeddings.swift` no longer
  diverges) — nothing left to drop.
- No overlap yet between fork changes and upstream commits landed after this
  sync's merge base (`b284133c5f..48bb6e799f`: notification taxonomy,
  referral links, Perplexity lane) — nothing to pre-drop next sync.
- `.github` fork tolerance patches (deployment-concurrency `absent` set,
  desktop-backend release policy, source admission, diff hygiene, lifecycle
  headers, `scripts/failure-class` inherited-definition filter,
  `scripts/pre-push` guards) are all still keyed off genuinely absent
  workflows and remain needed, except as noted in A1.
- All fork-added e2e `covers:` entries point at existing files. (Two flows
  also contain upstream-authored `desktop/Desktop/...` paths missing the
  `macos/` segment, but those lines are upstream's, out of scope.)
- App tests (`based_hardware_endpoint_defaults_test`, `fork_preference_defaults_test`,
  `frontend_template_router_test`, `native_ble_transport_test`,
  `photo_viewer_page_test`, `phone_setup_verify_page_test`) assert real
  behavior or clearly-labeled static tripwires; no tautological tests found.
- Desktop fork features (DockIconVisibilitySettings, IdeaCaptureToast,
  LocalSessionUploader, AppProvider setApp, ScreenCaptureService AX-type
  guards, TranscriptionService buffering, AuthService log sanitization,
  RewindDatabase retry/recovery) reviewed; no narration comments, no
  error-swallowing beyond commented, intentional fail-opens.

## Counts

| Area | Findings | Open questions |
|---|---|---|
| `.github` / workflows | 2 (A1 as question, C1) | 1 (codemagic recovery active) |
| `desktop/` | 4 (A2, A3, B1 as question, B2) | 2 (D1, B1 staging) |
| `app/` | 3 (B4, B5, C2) | 1 (D3) |
| `omi/` | 0 | 0 |
| `docs/` | counted within A2/C2 | 1 (D2) |

By severity: correctness-risk 1 (A1, latent, gated on owner decision);
maintainability 5 (A2, A3, B1, C2, C1-with-A1); cosmetic 3 (B2, B4, B5).
