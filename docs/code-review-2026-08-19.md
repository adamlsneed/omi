# Code review findings — 2026-08-19 upstream sync

Adversarial review of `upstream/main...HEAD` (the fork's divergence after merging
BasedHardware upstream `e0af1ee9d8`). GitHub issues are disabled on this fork, so open
findings are tracked here.

**Headline: none of these were introduced by the sync merge.** Every finding below is
pre-existing fork code whose logic the sync range did not touch (verified with
`git diff 7a128a39ba HEAD -- <file>` per file). The merge resolutions themselves came
back clean.

Fixed in the sync PR: a duplicated `_taskAutoPromoteEnabled` initializer in
`SettingsPage.swift`. A finding against `backend/utils/memory/l2_promotion_agent.py`
(unbounded agent loop on an unknown tool name) is moot: that file is deleted by this PR,
since `backend/` is a byte-exact upstream mirror and upstream replaced those modules.

Running the desktop Swift suite (which had not compiled since PR #100) surfaced two more
upstream defects. The first is fixed in this PR; the second is open, below.

### Fixed: compacted-screenshot CTE never projects `embedding` (upstream)
`desktop/macos/Desktop/Sources/Rewind/Core/RewindDatabase+Embeddings.swift`

`getCompactedScreenshotsMissingEmbeddings` builds a `ranked` CTE selecting
`id, ocrText, appName, windowTitle`, then filters the outer query on
`bucketRank = 1 AND embedding IS NULL`. `embedding` is never projected into the CTE, so
SQLite raises `no such column: embedding` and the call throws every time the
screenshot-embedding backfill re-arms. The file was byte-identical to upstream, so this
ships broken upstream. Fixed by adding `embedding` to the CTE projection, which preserves
the intent: rank the bucket by OCR length first, then require the winning row itself to be
missing an embedding.

## Open

### 1. Routed summary wedges forever when you switch conversations mid-request
`app/lib/pages/conversation_detail/conversation_detail_provider.dart`

`loadOrGenerateRoutedSummary` sets `routedSummaryLoading = true` and
`_routedSummaryRequestKey`, then awaits `testConversationPrompt`. Its `finally` resets
both **only** when the conversation is still current. `ConversationDetailProvider` is a
single app-wide provider, so switching conversations mid-flight skips the reset: the
stale key survives, and reopening the original conversation hits the
`if (_routedSummaryRequestKey == requestKey) return;` guard and returns immediately with
`routedSummaryLoading` still true. The "Applying local template…" spinner stays up
forever and no summary is generated until the app restarts.

Related: `_clearRoutedSummary()` on conversation switch is dead code. `page.dart` calls
`setCachedConversation(B)` (which sets `_cachedConversationId = B.id`) *before*
`updateConversation(...)`, so the `previousConversationId != conv.id` guard never fires
on the real navigation path.

Fix direction: reset unconditionally in `finally`, keyed on the captured conversation;
move the clear into `setCachedConversation`. Wants a regression test covering
start request → switch away → switch back.

### 2. Powering the pendant off leaves the app stuck in idea-capture mode
`omi/firmware/omi/src/lib/core/button.c`

`BUTTON_EVENT_HOLD` fires at >=1000 ms while still pressed, toggling
`idea_capture_active` and notifying `HOLD_ENTER` (6). Power-off is a >=3000 ms hold of
the same button, so it passes through 1 s first: the firmware enters idea capture, the
app sets `_ideaCaptureActive = true`, then `turnoff_all()` runs at 3 s and the device
disconnects. `HOLD_EXIT` (7) is never sent, so the home-screen lightbulb stays green
indefinitely and the next tap force-processes a conversation the user never meant to
capture.

Fix direction: notify `HOLD_EXIT` before `turnoff_all()`, or move the hold gesture off
the power-off button path. Needs a device flash to verify.

### 3. Haptic init failure leaves a work item uninitialized but reachable
`omi/firmware/omi/src/haptic.c`

`gpio_pin_configure_dt` moved into `haptic_init`, and its failure path returns **before**
`k_work_init_delayable(&haptic_off_work, ...)`. `main.c` treats a failed `haptic_init()`
as non-critical and keeps booting. `play_haptic_milli` only guards on
`gpio_is_ready_dt` (still true here), so it calls `k_work_cancel_delayable` and later
`k_work_schedule` on a zeroed `k_work_delayable` with a NULL handler: assert failure or a
NULL-handler fault on the first double-tap or BLE haptic write.

Fix direction: move `k_work_init_delayable` above the configure, or gate
`play_haptic_milli` on an init-succeeded flag. Needs a device flash to verify.

### 4. TX-slot timeout can transmit a partial audio frame
`omi/firmware/omi/src/lib/core/transport.c`

`push_to_gatt` splits one encoded frame into indexed sub-packets. Returning `false` on
`k_sem_take(..., K_MSEC(100)) != 0` happens mid-loop, so sub-packets 0..n-1 are already
on the air and the remainder is dropped: the phone reassembles a truncated Opus frame
rather than simply missing one. The stated rationale (a disconnect handler cannot wake a
`K_FOREVER` waiter safely) no longer holds, because `_transport_disconnected` now
drains and `k_sem_give`s specifically so a pended waiter is woken.

Fix direction: bail before sub-packet 0 rather than mid-frame, or restore `K_FOREVER`.
Needs a device flash to verify.

### 5. Toggling Apple Reminders auto-export can disconnect the integration
`app/lib/providers/task_integration_provider.dart`

`setAppleRemindersAutoExportEnabled` posts
`{'connected': _appleRemindersPermission, 'auto_export_enabled': enabled}`.
`_appleRemindersPermission` defaults to `false` and is only populated inside
`loadFromBackend`'s `if (PlatformService.isApple && !_appleRemindersPermissionManuallySet)`
branch. Flipping the switch before that load completes (or in a session where the
permission read was skipped) writes `connected: false`, and the backend stops treating
Apple Reminders as connected, breaking FCM-driven sync even though permission is granted.

Fix direction: merge into the existing `connected` value instead of re-asserting a
possibly-unloaded local flag.

### 6. Database recovery fans out unbounded retry tasks
`desktop/macos/Desktop/Sources/Rewind/Core/RewindDatabase.swift`

`getDatabaseQueue()` spawns `Task { try? await self.initialize() }` whenever
`dbQueue == nil && initializationTask == nil`. `initializationTask` is only assigned once
the spawned task actually runs, so a burst of callers (every read path calls
`getDatabaseQueue`) each observe `nil` and each spawn. Each spawned task then runs
`performInitializationWithRetry` with its own 0.5/1/2 s backoff. The
`consecutiveInitFailures < maxInitRetries` guard bounds this, so severity is moderate
rather than truly unbounded, but a failed startup still multiplies sqlite open attempts
while the UI is loading.

Fix direction: set a `pendingRecovery` flag synchronously before spawning.

### 7. Owner-snapshot test is order-dependent (upstream)
`desktop/macos/Desktop/Tests/RewindCaptureExclusionGenerationTests.swift`

`testOwnerSnapshotStaysCurrentWhenAuthLeadsUnresolvedRewindDatabase` passes in isolation
(`--filter RewindCaptureExclusionGenerationTests` is 9/9 green) but fails inside the full
5408-test run, where `RewindCaptureOwnerSnapshot.capture()` resolves `anonymous` instead of
the `auth_userId` the test just wrote.

`resolvedOwnerID` prefers `RuntimeOwnerIdentity.captureAuthorizationSnapshot()`, which
returns nil while `EffectiveOwnerAuthorizationRevocation.shared.isActive` or
`RuntimeOwnerAuthorizationAuthority.shared` is mid-transition. Both are process-wide
singletons shared by every test in the target, so an earlier test that begins an owner
transition without ending it makes every later owner resolution nil. The test file, the
production file (`RewindCaptureExclusion.swift`), and `RuntimeOwnerIdentity.swift` are all
byte-identical to upstream, so this is upstream's defect, and it is a test-hermeticity
problem rather than a production one: the production transition path is structured
begin/end.

AGENTS.md requires CI tests to be free of ordering dependence. Fix direction: give the
owner-authority singletons a test reset hook and call it in `setUp`, or find the polluting
suite by bisecting class order. Not fixed here to keep the sync PR reviewable.

## Checked and cleared

- `sdcard.c` `get_file_contents` bound: `count <= 1` at every body entry for `file_num_array[2]`.
- `mic.c` `mic_thread_started` + `mic_off()` -> `mic_pause()`: `mic_pause` issues `DMIC_TRIGGER_STOP` and the thread never exits, so the one-shot start guard is correct.
- `settings.c` `atomic_xor(...) == 0` toggles: return-previous-value semantics give the correct now-active/paused result.
- `RewindDatabase.addCaptureProvenance` migration vs the new `CREATE TABLE` columns: no duplicate-column conflict; that CREATE is in the corruption-recovery path, not the migrator.
- `APIClient.reprocessConversation` switching to `?app_id=` returning `ServerConversation`: matches `backend/routers/conversations.py`.
- `TranscriptionService` multi-channel framing: `sendAudio(_:channel:)` has no callers yet and `channels` defaults to 1, so the pre-connect buffer cannot emit unframed multi-channel data.
- `language_selection_dialog.dart` / `people.dart` controller `dispose()` after `await showDialog(...)`: awaited, so disposal happens after the dialog closes.
- `native_ble_transport.dart` onListen/onCancel rework: re-subscription on reconnect is preserved and the double-fire guard it replaced is no longer needed.
