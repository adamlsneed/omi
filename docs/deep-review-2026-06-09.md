# Deep Code Review: 2026-06-09

Full-codebase review (bugs, duplicates, dead code, performance), not limited to fork divergence. Seven parallel read-only review passes: app core, app UI + iOS native, desktop Swift, desktop Rust + scripts, firmware, backend (read-only), peripheral (web/mcp/sdks/plugins/omiGlass). Baseline for ownership tags: merge-base with upstream `fe69b82c3`.

Statuses:
- **fixed**: remediated on branch `review/deep-review-2026-06-09`.
- **documented**: real finding, intentionally not fixed in the fork (usually upstream-owned cleanup where a local edit would only widen the merge surface). Left for upstream to fix on their own; recheck after each pull.
- **backend-watch**: backend/ findings. The fork never modifies backend/ and never sends anything to BasedHardware (no pushes, PRs, or issues); these are tracked only so future upstream pulls can be checked for whether they got fixed.

The **Divergence ledger** section at the bottom lists every upstream-owned file this branch modifies and what to do when an upstream pull conflicts there.

---

## App core (services, providers, backend http, utils)

### AC1. Idea-capture BLE signals dropped while a button action is in flight — **fixed**
- `app/lib/providers/capture_provider.dart:873-894` (producer :742-751) — bug, med, fork-touched
- `_onIdeaCaptureSignal` shares `_isProcessingButtonEvent` with the mute/unmute path and drops the firmware ENTER(6)/EXIT(7) signal while the guard is held (pause/resume holds it across multiple awaited BLE writes). A dropped ENTER leaves `_ideaCaptureActive` false; the later EXIT then hits the `active == _ideaCaptureActive` short-circuit and the idea is never filed, silently.
- Fix: queue the latest pending signal while the guard is held and replay it when the guard clears.

### AC2. Apple Reminders auto-export toggle silently reverts when backend save fails — **fixed**
- `app/lib/providers/task_integration_provider.dart:174-184`, `:61-68` — bug, med-low, fork-touched
- Local pref and native side are written first; `saveConnectionDetails` result is ignored. On save failure the toggle looks enabled, then `loadFromBackend` (remote-wins) flips it back on next load with no feedback.
- Fix: on failed save, revert the local pref + native state and notify listeners.

### AC3. Bulk-delete rollback resurrects rows deleted server-side on partial success — **fixed**
- `app/lib/providers/action_items_provider.dart:753-778` — bug, low, fork-touched
- On partial server success the code re-inserts all snapshot rows (including ids the server confirmed deleted), so the UI shows ghosts until the next fetch and a retry re-sends deleted ids.
- Fix: roll back only ids not present in the returned `deleted` list.

### AC4. `BackgroundService.start()` leaks one `ui.ping` listener per mic start/restart — **fixed**
- `app/lib/services/services.dart:159-176` — bug, low-med, upstream-owned
- Every phone-mic start (incl. each automatic restart after an iOS audio interruption) registers a fresh never-cancelled `_service.on('ui.ping')` subscription and re-runs `configure(...)`.
- Fix: one-shot guard so listener registration/configuration happens once.

### AC5. `CaptureProvider.dispose()` misses `_bleButtonStream` and `_voiceCommandTimeoutTimer` — **fixed**
- `app/lib/providers/capture_provider.dart:1304-1318` — bug, low, upstream-owned
- Fix: cancel both in `dispose()`.

### AC6. `forceProcessingCurrentConversation` continuation has no error handler — **fixed**
- `app/lib/providers/capture_provider.dart:1788-1807` — bug, low-med, upstream-owned
- `CreateConversationResponse.fromJson(jsonDecode(...))` can throw, in which case the placeholder `'0'` processing conversation is never removed (permanent ghost "processing" row until restart).
- Fix: catch failures in the continuation and remove the placeholder.

### AC7. `getActionItems` implemented twice, copies drifted — **documented**
- `app/lib/backend/http/api/action_items.dart:8-42` vs `app/lib/backend/http/api/conversations.dart:566-593` — duplicate, med, upstream-owned
- Two top-level functions hit `/v1/action-items` with different query-param shapes (`completed` vs `include_completed`) and different date serialization (UTC-normalized vs raw). Both have live call sites. Consolidation belongs upstream; a fork edit would widen the merge surface for no fork benefit.

### AC8. Dead members in CaptureProvider — **documented**
- `capture_provider.dart:394-396` (`_storageStream`/`storageStream`, never assigned), `:384` (`bleBytesStream` getter, no callers), `:445-449` (`setConversationCreating`, commented-out body, no callers) — dead-code, upstream-owned. Leave for upstream.

### AC9. Fork-added `getFeatures({bool refresh})` parameter is caller-less — **fixed**
- `app/lib/services/devices/device_connection.dart:607-615` — dead-code, fork-touched
- Its only caller was removed by the prior slop-audit remediation. Fix: drop the param, restoring upstream's signature (shrinks the merge surface).

### AC10. Template-routing result cache decodes the whole blob on every read/write — **fixed**
- `app/lib/services/frontend_template_router.dart:331-377` — perf, med-low, fork-touched
- `resultForConversation` jsonDecodes up to 500 cached summaries synchronously on the UI isolate; opening a conversation detail does this twice, saving a third time.
- Fix: memoize the decoded map across store instances, invalidate on save.

### AC11. Duplicate unmute BLE write on every resume — **fixed**
- `capture_provider.dart:2250-2252` and `:1098-1100` — perf, low, fork-touched
- `resumeDeviceRecording` writes unpause, then `_initiateDeviceAudioStreaming` immediately repeats the identical write. Fix: drop the explicit duplicate (the streaming-init path covers it).

### AC12. `searchConversationsServer` decodes the response body three times — **documented**
- `app/lib/backend/http/api/conversations.dart:538-540` — perf, low, upstream-owned. One-line fix that belongs upstream; not worth fork divergence.

### AC13. People cache JSON re-decoded per transcript event — **documented**
- `capture_provider.dart:165-169` + `preferences.dart:530-537` — perf, low, upstream-owned. Decoded-people memoization belongs upstream.

## App UI + iOS native

### AU1. Wrapped 2025 page: setState after awaits with no mounted guards — **fixed**
- `app/lib/pages/settings/wrapped_2025_page.dart:113,125,137,175,184` — bug, med-high, upstream-owned
- Release-mode crash ("Null check operator used on a null value") when backing out mid-request; the async poll-timer callback survives `dispose()`'s cancel. Fix: `if (!mounted) return;` after each await.

### AU2. Chat conversation chip tap: setState + context after fetch without mounted — **fixed**
- `app/lib/pages/chat/widgets/ai_message.dart:812-820` — bug, med, upstream-owned
- Also: the `m == null` early return leaves the chip's loading flag stuck true, permanently blocking re-tap. Fix: mounted guard + reset flag on the null path.

### AU3. Action item toggle: setState on unmounted tile after 500ms delay — **fixed**
- `app/lib/pages/action_items/widgets/action_item_tile_widget.dart:75-86` — bug, med, upstream-owned
- `onToggle` typically removes the tile from the list, so the post-toggle setState frequently runs unmounted on a core hot path. Fix: mounted guards.

### AU4. Create-template sheet: setState + context.l10n after network awaits — **fixed**
- `app/lib/pages/conversation_detail/widgets/create_template_bottom_sheet.dart:89-115` — bug, med, upstream-owned
- Dismissing the sheet mid-generation crashes on the next setState. Fix: mounted guards after each await.

### AU5. API keys widget: unguarded setState in create/delete — **fixed**
- `app/lib/pages/apps/widgets/api_keys_widget.dart:58,69,113-119` — bug, low-med, upstream-owned
- Sibling `_loadApiKeys` guards correctly; these two are omissions. Fix: mirror its mounted guards.

### AU6. Analytics event fired inside build() of summarized-apps sheet — **documented**
- `app/lib/pages/conversation_detail/widgets/summarized_apps_sheet.dart:39-43` — metrics bug, med, upstream-owned
- "Sheet viewed" fires on every notifyListeners while open. Fix belongs upstream (their analytics data).

### AU7. Conversation detail tab analytics double-fires per tab switch — **documented**
- `app/lib/pages/conversation_detail/page.dart:163-189` — metrics bug, low, upstream-owned. TabController notifies twice per tap; upstream's call.

### AU8. Template-routing settings: `onPicked` setState without mounted after sheet await — **fixed**
- `app/lib/pages/settings/frontend_template_routing_settings_page.dart:103` — bug, low, fork-touched
- Fix: `if (selected != null && mounted)`.

### AU9. ~12 pages and ~7 widgets are dead code (zero call sites) — **documented**
- `SelectTextScreen`, `CategoryMemoriesPage`, `PrivacyInfoPage`, `DailySummarySettingsPage`, `AboutOmiPage`, `PaypalSetupPage`, `SetupQuestionsPage`, `AboutSdCardSync`, `SdCardTransferProgress`, `RecordingsStoragePermission`, `ConversationCreatedWidget`, `DeviceOnboardingWrapper`; widgets `ConversationAudioPlayerWidget`, `CustomRefreshIndicator`, `GradientButton`, `AnimatedMiniBanner`, `OutOfCreditsWidget`, `ChatAppsDropdownWidget`, `LimitlessSyncCardWidget`, `EmptyAppsWidget` — upstream-owned. Do not delete in the fork (pure merge-surface cost); useful to know nothing routes to them.

### AU10. Large near-duplicate page pairs (upstream copy-paste clusters) — **documented**
- `delete_account.dart` ≈ `cancel_subscription_sheet.dart`; `auto_sync_page.dart` ≈ `sync_page.dart`; `add_app.dart` ≈ `update_app.dart`; `firmware_update.dart` ≈ `omiglass_ota_update.dart`; onboarding pairs; 4x OAuth connect blocks in `task_integrations_page.dart`. Consolidation belongs upstream. When the fork edits one copy, remember to mirror the siblings.

### AU11. Leaked controllers (created, never disposed) — **documented**
- `name_speaker_sheet.dart:36`, `onboarding/name/name_widget.dart:17-23`, `language_selection_dialog.dart:40`, `add_review_widget.dart`, `app_owner_review_card.dart`, `settings/people.dart`, `processing_conversations/page.dart` — minor leaks, upstream-owned.

### AU12. BuildContext across async gaps (~45 further latent sites) — **documented**
- Worst: `conversation_capturing/page.dart:126-127,159-161`, `memory_graph_page.dart:563-566`, `stripe_connect_setup.dart:217,280,356`, `apple_watch_setup_bottom_sheet.dart:198-220`, `test_prompts.dart:82-87`. AU1-AU5 were the sites where unmount-mid-await is actually likely; the rest are latent.

## Desktop Swift

### DS1. Rewind corruption recovery deadlocks on the sqlite3 `.recover` pipe — **fixed**
- `desktop/Desktop/Sources/Rewind/Core/RewindDatabase.swift:661-685` — bug, high, upstream-owned
- `waitUntilExit()` before reading the pipe: `.recover` output exceeds the ~64KB pipe buffer on any real DB, sqlite3 blocks, the continuation never resumes, and `initialize()` hangs forever — the recovery path wedges instead of recovering. Also materializes a potentially multi-GB dump in memory.
- Fix: stream `.recover` output to a temp file (no pipe to fill, no in-memory dump), wait after the output is drained.

### DS2. GmailReaderService / ChatLabView use the same wait-then-read pipe pattern — **fixed**
- `desktop/Desktop/Sources/GmailReaderService.swift:773-787`, `MainWindow/Pages/ChatLabView.swift:226-234` — bug, med, upstream-owned
- `CalendarReaderService.swift:625-668` is the already-fixed twin (comment: "waitUntilExit blocks if pipe buffers are full"). Fix: same readabilityHandler + timeout pattern in both remaining sites.

### DS3. Active-window resolver's 500ms "timeout" cannot unblock the caller — **fixed (contained)**
- `desktop/Desktop/Sources/ScreenCaptureService.swift:480-501` — bug/perf, med, upstream-owned
- `withTaskGroup` awaits all children, and `cancelAll()` cannot interrupt the synchronous CGWindowList/AX child, so a SkyLight stall still blocks the capture tick for its full duration. Fix: race a detached lookup against the timeout via a continuation so the caller returns early; the late result still lands in the snapshot cache.

### DS4. Pre-connection audio buffer uncapped, flushes as one giant WS frame — **fixed**
- `desktop/Desktop/Sources/TranscriptionService.swift:263-285,305-314,447` — bug, med, fork-touched
- The fork's PTT lead-in buffering also buffers conversation-mode audio (~32KB/s) without cap during disconnected windows (reconnect backoff can span minutes), then flushes the whole accumulation as a single WebSocket message.
- Fix: cap the buffer (drop oldest), flush in normal-sized chunks.

### DS5. Send watchdog force-release lets two `agentBridge.query()` loops interleave — **fixed (contained)**
- `desktop/Desktop/Sources/Providers/ChatProvider.swift:2649-2658, 2353-2360`; mechanics in `Chat/AgentBridge.swift:518-524, 826-855` — bug, med, upstream-owned
- When the 180s watchdog (or stopAgent's 3s fallback) resets `isSending` without stopping the bridge, the next send starts a second concurrent query loop on the same bridge; inbound messages can be consumed by the dead loop. Fix: interrupt/restart the bridge when the watchdog force-releases.

### DS6. `willTerminate` cleanup wrapped in `Task { @MainActor }` never executes — **fixed**
- `Providers/ChatProvider.swift:858-867`, `AppState.swift:584-597` — bug, low, upstream-owned
- The spawned task is only enqueued; AppKit exits before it runs, so the "kill agent bridge subprocess on quit" comment is a no-op. Fix: do the cleanup synchronously in the handler (the pattern `AppDelegate.applicationWillTerminate` already uses).

### DS7. Free-tier chat quota consumed even when the send fails before reaching the model — **fixed**
- `Providers/ChatProvider.swift:2605` vs early returns at 2609-2614, 2630-2633, 2666-2671 — bug, low, upstream-owned
- Fix: move `recordQuery()` after all early-return guards, just before `agentBridge.query(...)`.

### DS8. ISO8601 parse helpers duplicated; APIClient allocates two formatters per date field — **fixed (APIClient only)**
- `APIClient.swift:53-72` (hot path) with copies at `AppState.swift:68-86`, `GmailReaderService.swift:946-952`, `CalendarReaderService.swift:285`; the `{current_datetime_*}` substitution block also exists twice (`ChatProvider.swift:1846-1861` vs `ChatPrompts.swift:1396-1409`) — duplicate/perf, low, mixed
- Fix applied: static cached formatters in APIClient's decoder. The cross-file consolidation is documented only (merge-surface).

### DS9. Verbatim duplicate keychain reader + python-path resolver in Gmail vs Calendar readers — **documented**
- `GmailReaderService.swift:922-944` ≡ `CalendarReaderService.swift:721-743`; identical `pythonPaths` lists. Already diverged once (the DS2 pipe fix existed only in Calendar). Hoisting belongs upstream.

### DS10. Dead code in ScreenCaptureService — **documented**
- `testCapturePermission` (:130), `testCaptureCapability` (:136), sync `captureActiveWindow()` (:922), `getActiveWindowID` (:424) — zero call sites; deletion deferred to upstream.

## Desktop Rust + scripts

### DR1. OAuth callback injects unescaped client-controlled values into HTML/JS — **fixed**
- `desktop/Backend-Rust/src/routes/auth.rs:665-674`, `templates/auth_callback.html:96-99,113` — security bug, high, upstream-owned
- `state`/`redirect_uri` from the attacker-controllable authorize query are spliced into JS string literals by naive `String::replace`; `redirect_uri` has no allowlist and flows into `window.location.href`. Reflected XSS + OAuth-code exfiltration on the local backend origin.
- Fix: JSON-encode all substituted values; reject `javascript:`/`data:`/`vbscript:` redirect schemes at authorize time.

### DR2. `AuthSessionStore` never evicts sessions/codes — **fixed**
- `src/routes/auth.rs:53-99` — unbounded growth, med, upstream-owned
- Fix: prune expired entries on insert (same idea as the rate limiter's `evict_stale`).

### DR3. Gemini proxy builds a fresh `reqwest::Client` per request, no timeouts — **fixed**
- `src/routes/proxy.rs` (10 sites) — perf + missing-timeout bug, med, upstream-owned
- Fix: one shared client (connect timeout) reused across handlers; total timeout on non-streaming calls only.

### DR4. `IntegrationService` constructed but never invoked — **documented**
- `src/services/integrations.rs`, `main.rs:54,173,257` — ~395 lines of unreachable webhook-trigger code; upstream may re-wire it. Leave.

### DR5. Most `FirestoreService` CRUD shadows deprecated 410 routes — **documented**
- `src/services/firestore.rs` (~9k lines, only ~14 methods live) — informational; do not prune in the fork.

### DR6. `omi-ctl action` builds JSON params via unescaped string concatenation — **fixed**
- `desktop/scripts/omi-ctl:48-52` — bug, low, fork-touched
- Fix: build params with `jq -n --arg`.

## Firmware (omi/)

### FW1. `OMI_FEATURE_RECORDING_PAUSE` defined but never advertised — **fixed**
- `omi/firmware/omi/src/lib/core/features.h:19` — dead-code, fork-touched
- The bit is never ORed into `features_read_handler` and the app never reads it; pure dead code on both ends. Fix: delete the enum value (fork-added line; removal restores upstream bytes).

### FW2. DevKit: use-after-free in `initialize_audio_file()` — **fixed**
- `omi/firmware/devkit/src/sdcard.c:226-235` — bug, high (devkit target only), upstream-owned
- `k_free(header)` runs before `create_file(header)` dereferences it. Fix: free after use.

### FW3. DevKit: `remaining_length` underflow in storage `write_to_gatt()` — **fixed**
- `omi/firmware/devkit/src/storage.c:272-286` — bug, med (devkit only), upstream-owned
- Decrements by constant `SD_BLE_SIZE` instead of `packet_size`; final partial chunk underflows the u32 and the loop reads past EOF until the link drops. `offset` also advances before the error check, dropping failed chunks. Fix: account by `packet_size`, advance only on success.

### FW4. DevKit: out-of-bounds writes into `file_num_array[2]` — **fixed**
- `omi/firmware/devkit/src/sdcard.c:260-283` — bug, med (latent; masked by hard-coded file_count=1), upstream-owned
- Fix: bound the loop at the array size.

### FW5. DevKit: unreachable BLE-backpressure retry branch in `push_to_gatt()` — **documented**
- `omi/firmware/devkit/src/transport.c:581-603` — the `-EAGAIN/-ENOMEM` branch is dead (first `if (err)` consumes every error). Restructuring upstream's error handling is not worth fork divergence; the CV01 target already solves this properly with `audio_tx_sem`.

Note: no correctness bugs were found in the fork's CV01 divergence (atomics, mic pause/resume rework, and sd_card changes all verified clean). Minor watch-item: `haptic.c` now configures the pin only in `haptic_init`; if that one configure fails, later plays drive an unconfigured pin (extremely low likelihood).

## Backend (read-only; backend-watch only — the fork never modifies backend/ or contacts upstream)

### BE1. Sync Firestore/Redis calls block the event loop inside `/v4/listen` hot loops — **backend-watch**
- `backend/routers/transcribe.py` — high, confirmed by the repo's own `scan_async_blockers.py`. Hottest: `stream_transcript_process` (sync `update_conversation_segments`, `update_conversation_finished_at`, `store_conversation_photos`, per-segment `get_person_by_name`/`create_person`), `conversation_lifecycle_manager` (sync `get_conversation` every 5s), 60s usage loop (~720-doc Firestore query on-loop). Also `agent-proxy/main.py:398,210-234`.

### BE2. Cross-thread race on `realtime_segment_buffers` drops segments / can kill the session — **backend-watch**
- `transcribe.py:2130-2131` vs the Deepgram listener-thread producer — snapshot-then-`clear()` loses appends in between; `sorted()` over a deque mutated cross-thread raises and tears down the session. Fix: `popleft()` drain.

### BE3. Pusher flush clears buffers before send is confirmed — **backend-watch**
- `transcribe.py:1177-1184, 1259-1270` — on `ConnectionClosed`, up to 10MB audio / 1000 segments are dropped at exactly the moment the reconnect machinery should protect them. Fix: clear on success only.

### BE4. `SafeDeepgramSocket` does blocking network I/O and a thread join on the event loop — **backend-watch**
- `utils/stt/safe_socket.py:119-137, 157-165` — sync DG write under a lock shared with the keepalive thread, called every ~30ms of audio; `finish()` joins threads in async teardown. Modulate/Parakeet already use the queue+sender-task pattern.

### BE5. 8-minute `time.sleep` deferred-delete jobs park `storage_executor` workers — **backend-watch**
- `utils/chat.py:66-72,181-186,255-260`, `routers/sync.py:966-971`, `utils/conversations/postprocess_conversation.py:76,148-152` — sustained >~16 files/min saturates the 128-worker pool for 8 minutes at a time, stalling all GCS work.

### BE6. Pusher's `/v1/trigger/listen` trusts an unauthenticated `uid` query param — **backend-watch**
- `routers/pusher.py:676-682` — internal-ingress only, but any VPC foothold can impersonate any user: inject fabricated transcripts, force `process_conversation` (incl. attacker `byok_keys`), append audio to private storage. Fix: service-to-service credential.

## Peripheral (web, mcp, sdks, plugins, omiGlass)

### PX1. `getTrends` returns a raw `Response` on non-OK instead of an error value — **fixed**
- `web/frontend/src/actions/trends/get-trends.ts:11` — bug, med, upstream-owned
- Truthy `Response` passes the consumer's `!trends` check and throws at `trends.reduce`. Fix: return `undefined`, matching the catch path.

### PX2. Category heading lookup uses the literal `'category'` instead of the variable — **fixed**
- `web/frontend/src/components/trends/get-trends-main-page.tsx:39` — bug, low, upstream-owned
- Fix: `categories[category] ?? ...` (sibling lines 46/91 already do this).

### PX3. MCP `get_conversations` crashes whenever a category filter is supplied — **fixed**
- `mcp/src/mcp_server_omi/server.py:243` (cause :407) — bug, high, upstream-owned
- Raw JSON strings are passed where `ConversationCategory` enums are required (`c.value` AttributeError). Fix: convert like the GET_MEMORIES branch does.

### PX4. `mcp/tests/test_server.py` is stale and cannot run — **documented**
- Missing `uid` fixture, outdated signatures, nonexistent enum members; every test errors at collection. Deletion/rewrite belongs upstream.

### PX5. Orphaned `web/frontend/sitemap.ts` (wrong location, wrong base URL) + its only dependency — **documented**
- Never executed (must be `src/app/sitemap.ts`); builds URLs from `API_URL`. `get-public-memories-prerender.ts` (40k-memory fan-out) is dead with it.

### PX6. `PaidAmountDialog` unreferenced; reads a server-only secret from a client component — **documented**
- `src/components/dashboard/paidamount.tsx:39` — would send `Bearer undefined`; if "fixed" by making the key public it would leak an admin credential. Deletion belongs upstream.

### PX7. Dead trends/tendencies component tree — **documented**
- `tendencies.tsx`, `tendencies/{trending-banner,trending-item,get-trends}.tsx`, `trends/trend-item.tsx` — zero imports; live UI is `get-trends-main-page.tsx` + `trend-topic-item.tsx`.

### PX8. Thumbnail upload pipeline exceeds the server-action body limit for legitimate images — **documented**
- `create-app/page.tsx:126,403` + `next.config.mjs:21` — 10MB-per-file client validation × base64 inflation vs `'10mb'` action body cap; passes validation then fails opaquely. Architectural fix belongs upstream.

### PX9. React Native SDK ships stale compiled JS shadowing the TS sources under Metro — **documented**
- `sdks/react-native/src/index.js`, `src/types.js` — Metro resolves `.js` first, so consumers load a legacy NativeModules build; `mapCodecToName` is `undefined` at runtime. Deletion belongs upstream.

### PX10. omiGlass agent drops the per-image separator (no-op expression) — **fixed**
- `omiGlass/sources/agent/Agent.ts:57` — bug, low, upstream-owned
- `combined + '\n\nImage #' + i` discards its result (missing `+=`). Fix: `+=`.

### PX11. omiGlass dead OpenAI helpers calling nonexistent endpoints — **documented**
- `sources/modules/openai.ts` `transcribeAudio`/`describeImage` — unimported and unusable as written. Deletion belongs upstream.

---

## Divergence ledger (upstream-owned files this branch modifies)

These edits are deliberate local fixes to upstream-owned code. At every upstream pull, check this table first: if upstream has fixed the same issue (same function), **take upstream's version and drop ours**; otherwise re-apply/keep ours. All edits are small and function-local to keep conflicts cheap.

| File | Finding | Conflict guidance |
| --- | --- | --- |
| `app/lib/services/services.dart` | AC4 | One-shot guard around `ui.ping` listener + `configure`. If upstream reworks `MicRecorderBackgroundService`, prefer theirs if it dedupes the listener. |
| `app/lib/providers/capture_provider.dart` | AC5, AC6 | Two added cancels in `dispose()`; error handling around the `processInProgressConversation` continuation. File is already heavily fork-touched. |
| `app/lib/pages/settings/wrapped_2025_page.dart` | AU1 | Added `mounted` guards only. |
| `app/lib/pages/chat/widgets/ai_message.dart` | AU2 | Added `mounted` guard + loading-flag reset in `MemoriesMessageWidget.onTap`. |
| `app/lib/pages/action_items/widgets/action_item_tile_widget.dart` | AU3 | Added `mounted` guards in `_handleToggle`. |
| `app/lib/pages/conversation_detail/widgets/create_template_bottom_sheet.dart` | AU4 | Added `mounted` guards in `_createTemplate`. |
| `app/lib/pages/apps/widgets/api_keys_widget.dart` | AU5 | Added `mounted` guards in `_createApiKey`/`_deleteApiKey`. |
| `desktop/Desktop/Sources/Rewind/Core/RewindDatabase.swift` | DS1 | `.recover` output streamed to a temp file instead of an undrained pipe. If upstream rewrites `attemptDataRecovery`, take theirs if it drains the pipe before `waitUntilExit`. |
| `desktop/Desktop/Sources/GmailReaderService.swift` | DS2 | `runPython` uses the CalendarReaderService drain pattern. |
| `desktop/Desktop/Sources/MainWindow/Pages/ChatLabView.swift` | DS2 | Same drain pattern for `git show`. |
| `desktop/Desktop/Sources/ScreenCaptureService.swift` | DS3 | Timeout race actually abandons the stalled lookup. |
| `desktop/Desktop/Sources/Providers/ChatProvider.swift` | DS5, DS6, DS7 | Watchdog restarts the bridge; willTerminate cleanup synchronous; `recordQuery()` moved after guards. |
| `desktop/Desktop/Sources/Chat/AgentBridge.swift` | DS5, DS6 | Lock-guarded `TerminationProcessBox` + nonisolated `terminateProcessNow()` so willTerminate can kill the Node subprocess synchronously. If upstream adds its own quit-time teardown, prefer theirs. |
| `desktop/Desktop/Sources/AppState.swift` | DS6 | willTerminate transcription stop made synchronous. |
| `desktop/Desktop/Sources/APIClient.swift` | DS8 | Static cached ISO8601 formatters in the date decoding strategy. |
| `desktop/Backend-Rust/src/routes/auth.rs` | DR1, DR2 | Escaped template substitution (`js_string_literal`) + redirect-scheme deny-list + 3 security tests; session/code eviction on insert. Security fixes: keep ours unless upstream ships equivalent escaping. |
| `desktop/Backend-Rust/templates/auth_callback.html` | DR1 | Placeholders unquoted (backend now substitutes complete JSON-encoded JS literals). Must stay in sync with `render_auth_callback`; if upstream edits the template, re-apply the unquoting or take their escaping wholesale. |
| `desktop/Backend-Rust/src/routes/proxy.rs` | DR3 | Shared `reqwest::Client` + timeouts. |
| `omi/firmware/devkit/src/sdcard.c` | FW2, FW4 | Free-after-use; bounded file loop. |
| `omi/firmware/devkit/src/storage.c` | FW3 | Byte accounting by `packet_size`, advance on success only. |
| `web/frontend/src/actions/trends/get-trends.ts` | PX1 | Return `undefined` on non-OK. |
| `web/frontend/src/components/trends/get-trends-main-page.tsx` | PX2 | `categories[category]`. |
| `mcp/src/mcp_server_omi/server.py` | PX3 | Category strings converted to enum members. |
| `omiGlass/sources/agent/Agent.ts` | PX10 | `combined +=`. |

Fork-touched files also edited on this branch (no upstream conflict risk beyond what already existed): `app/lib/providers/capture_provider.dart` (AC1, AC11), `app/lib/providers/task_integration_provider.dart` (AC2), `app/lib/providers/action_items_provider.dart` (AC3), `app/lib/services/devices/device_connection.dart` (AC9, divergence-reducing), `app/lib/services/frontend_template_router.dart` (AC10), `app/lib/pages/settings/frontend_template_routing_settings_page.dart` (AU8), `desktop/Desktop/Sources/TranscriptionService.swift` (DS4), `desktop/scripts/omi-ctl` (DR6), `omi/firmware/omi/src/lib/core/features.h` (FW1, divergence-reducing).

## Summary

| Area | Findings | Fixed | Documented | Backend-watch |
| --- | --- | --- | --- | --- |
| App core | 13 | 9 | 4 | — |
| App UI + iOS | 12 | 6 | 6 | — |
| Desktop Swift | 10 | 8 | 2 | — |
| Desktop Rust + scripts | 6 | 4 | 2 | — |
| Firmware | 5 | 4 | 1 | — |
| Backend | 6 | — | — | 6 |
| Peripheral | 11 | 4 | 7 | — |
| **Total** | **63** | **35** | **22** | **6** |

## Verification

- App: `flutter analyze` zero new issues vs baseline (5 pre-existing `use_build_context_synchronously` infos resolved as a side effect); `app/test.sh` 520/520 passed.
- Desktop Swift: debug build clean (no new warnings); `swift test` 427/427 passed; clean release build (`rm -rf .build && xcrun swift build -c release --triple arm64-apple-macosx`) succeeded, required because DS5/DS6 add a cross-file AgentBridge method.
- Desktop Rust: `cargo check` clean (5 pre-existing warnings unchanged); `cargo test` 258/258 passed, including 3 new DR1 security tests kept in `auth.rs`.
- omi-ctl: `bash -n` clean; params builder verified against values containing quotes, backslashes, newlines (output parses with `jq`).
- MCP: `python3 -m py_compile` passed.
- Firmware: no Zephyr build run (devkit toolchain not set up locally); edits are small and were re-read in full, and the CV01 target is untouched except the dead-enum removal in `features.h`. Build before any devkit flash.
- Web/omiGlass: one-line fixes, no node_modules in the worktree; verified by reading the surrounding types.
