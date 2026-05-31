# Frontend Template Routing Design

## Goal

Build a frontend-controlled template router for Adam's Omi app so completed conversations are summarized with a work prompt during work hours and a personal prompt outside work hours, while continuing to use BasedHardware's hosted backend for capture, transcription, auth, storage, and subscription-backed processing.

## Current Reality

BasedHardware's backend currently applies memory-app templates during conversation processing. Adam can create a simple, generic backend template so the hosted backend always has a safe default. The fork should not depend on modifying or deploying Adam's own backend for normal usage.

The mobile app already has a useful frontend-controlled hook:

- `app/lib/backend/http/api/conversations.dart`
- `testConversationPrompt(prompt, conversationId)`
- Hosted route: `POST /v1/conversations/{conversation_id}/test-prompt`

That route runs a caller-provided prompt against the stored conversation transcript. It does not change the backend's automatic template selection, but it lets the frontend request a routed summary after the conversation exists.

## Chosen Approach

Implement a local mobile "Template Router" layer that runs after a conversation is available on the client.

The router chooses between two local prompt profiles:

- Work profile: Monday through Friday, 8:00 AM through 5:00 PM.
- Personal profile: all other times.

The chosen prompt is sent through `testConversationPrompt(prompt, conversationId)`. The result is stored locally as a routed summary overlay, displayed ahead of the backend-generated app result when routing is enabled.

This keeps BasedHardware's backend as the source of truth for capture and transcript processing, while letting Adam control the practical interpretation layer from the frontend.

## Why Not Disable Backend Routing Directly

With BasedHardware's hosted backend, the fork cannot reliably prevent their deployed backend from running its default memory-app routing. Even if fork-side backend code adds a disable flag, that change only matters after BasedHardware deploys it.

The frontend should therefore treat backend template results as a fallback, not as the user-facing source of truth when local routing is enabled.

## User-Facing Settings

Add a mobile settings surface for local template routing.

Fields:

- Enabled: default `false` for safety.
- Work days: default Monday, Tuesday, Wednesday, Thursday, Friday.
- Work start time: default `08:00`.
- Work end time: default `17:00`.
- Work prompt: required when enabled.
- Personal prompt: required when enabled.
- Auto-run mode: default `on_open`.

The first version does not need a full day picker UI if that would slow implementation. It can start with the fixed Monday-Friday rule and editable start/end times plus prompts.

## Routing Rules

Use the conversation's local started time when available. If `startedAt` is absent, use `createdAt`.

Work profile applies when all are true:

- Local weekday is Monday-Friday.
- Local time is at or after 8:00 AM.
- Local time is before 5:00 PM.

Personal profile applies otherwise.

The end time is exclusive. A conversation at exactly 5:00 PM is personal.

## Prompt Composition

The local profile prompt is the instruction body Adam controls. The frontend should wrap it with a small stable preface so both profiles get consistent context.

Prompt shape:

```text
You are summarizing an Omi conversation for Adam.

Routing profile: Work|Personal
Conversation local time: <weekday, date, time>
Conversation source: <source or unknown>

Follow these instructions:
<Adam profile prompt>
```

The backend route supplies the transcript from the stored conversation, so the frontend does not need to include transcript text in this first version.

## Local Storage

Persist settings in `SharedPreferencesUtil` as JSON under a single key:

`frontendTemplateRoutingConfig`

Persist routed results locally under a separate key:

`frontendTemplateRoutingResults`

Result shape:

```json
{
  "conversation_id": {
    "profile": "work",
    "prompt_hash": "stable hash of prompt text and router settings",
    "content": "generated summary",
    "generated_at": "ISO-8601 timestamp",
    "conversation_started_at": "ISO-8601 timestamp"
  }
}
```

If the prompt hash or selected profile changes, the app should regenerate on the next eligible open.

## Display Behavior

In conversation detail:

1. If local template routing is disabled, display the existing backend app result behavior unchanged.
2. If enabled and a routed result exists, show it before backend app results with a clear local label such as "Routed Summary".
3. If enabled and no result exists, generate it in the background when the conversation detail opens, then update the UI.
4. If generation fails, keep showing the backend summary/app result and expose a retry affordance.

The first version should not overwrite `apps_results` or `structured.overview`. Local overlay avoids fighting the hosted backend and avoids changing server data unexpectedly.

## Error Handling

- Missing prompts while enabled: do not run; show a settings warning.
- Empty transcript response from backend: keep fallback summary.
- Network failure: keep fallback summary and allow retry.
- Rate limit failure: keep fallback summary and show a non-blocking error.
- Conversation still processing: defer generation until the conversation status is completed.

## Future Desktop Extension

Desktop can reuse the same routing decision and prompt profiles later, but add local Rewind context:

- active apps/windows around the conversation time,
- selected screenshot OCR/accessibility text,
- local desktop task context,
- meeting/browser context.

That should be a second pass because the mobile router already solves the immediate work/personal split for Omi conversations.

## Testing Strategy

Unit tests:

- Router selects work profile Monday-Friday at 8:00 AM.
- Router selects work profile before 5:00 PM.
- Router selects personal profile at exactly 5:00 PM.
- Router selects personal profile on weekends.
- Router falls back from `startedAt` to `createdAt`.
- Prompt composer includes profile, source, local time, and Adam's prompt.
- Result cache invalidates when selected profile or prompt hash changes.

Integration-style widget/provider tests:

- Conversation detail uses routed result when present.
- Conversation detail falls back to backend app result when local routing is disabled.
- Conversation detail falls back when generation fails.

Manual checks:

- Open a work-hours conversation and confirm the work prompt result appears.
- Open an off-hours conversation and confirm the personal prompt result appears.
- Toggle routing off and confirm the existing backend summary/app result returns.

## Open Deployment Note

This feature depends on BasedHardware's hosted `/test-prompt` endpoint remaining available. If that endpoint changes or rate limits too aggressively, the fallback is to route through the macOS desktop local AI bridge for desktop-only summaries, or to add a small backend endpoint once BasedHardware accepts the fork-side routing API.
