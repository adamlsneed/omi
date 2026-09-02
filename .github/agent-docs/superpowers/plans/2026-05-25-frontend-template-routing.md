# Frontend Template Routing Implementation Plan

## Goal

Implement an isolated mobile frontend router that lets Adam choose work-hours and personal conversation prompts while still using BasedHardware's hosted backend for auth, capture, transcription, storage, and prompt execution.

## Scope

- Add local routing models and service code in the Flutter app.
- Persist routing config and routed summaries locally with `SharedPreferences`.
- Add Profile settings for enabling routing, editing work hours, and entering the work/personal prompts.
- Run routed summary generation when a completed conversation detail screen opens.
- Display the local routed summary before backend app results when it exists.
- Keep backend-generated results untouched as fallback.

## Design Constraints

- Do not alter hosted backend assumptions or point the app away from BasedHardware's backend.
- Do not overwrite `apps_results` or `structured.overview` for routed summaries.
- Default routing to disabled so existing behavior remains unchanged until Adam opts in.
- Work hours are Monday-Friday, start inclusive, end exclusive. Adam's current default is `08:00` to `17:00`.
- Treat conversations at exactly `17:00` as personal.
- Use conversation `startedAt` when available and fall back to `createdAt`.

## Implementation Steps

1. Add unit tests for routing profile selection, prompt composition, config JSON, and cache invalidation.
2. Implement `FrontendTemplateRoutingConfig`, `FrontendTemplateRoutingResult`, and `FrontendTemplateRouter`.
3. Add `SharedPreferencesUtil` accessors for `frontendTemplateRoutingConfig` and `frontendTemplateRoutingResults`.
4. Add a settings page under Profile for enabling/disabling routing, editing times, and editing both prompt bodies.
5. Integrate with `ConversationDetailProvider`:
   - load cached routed summary during `initConversation`;
   - generate via `testConversationPrompt` only when enabled, configured, and completed;
   - save successful results locally;
   - keep backend summary as fallback on empty response or errors.
6. Update summary display selection so routed results win while enabled.
7. Add focused tests for preferences and router behavior.
8. Run Flutter unit tests and static checks where the local toolchain allows.

## Verification

- `flutter test test/unit/frontend_template_router_test.dart`
- `flutter test test/unit/frontend_template_routing_preferences_test.dart`
- Existing Apple Reminders preference test remains passing.
- `git diff --check`

If Flutter is unavailable, install or activate it with FVM/Homebrew in this worktree and document any remaining toolchain blockers.
