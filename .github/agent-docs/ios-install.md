# iPhone build and install (fork)

How any agent builds the iOS app with Adam's signing and installs it on his iPhone. Use
it whenever Adam asks to build, install, or update the iPhone app, from any checkout or
worktree:

```bash
scripts/fork/ios-install.sh                # build, install, launch, verify
scripts/fork/ios-install.sh --no-install   # build only
scripts/fork/ios-install.sh --device <id>  # another paired device (default: Adam's iPhone)
```

It builds the tree it lives in. A cold build takes about 7 minutes; an incremental one
about 2. Step logs go to `app/build/ios-install-logs/`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Installed, launched, and the Omi process is running (or built, with `--no-install`) |
| 1 | Prerequisite, config, or build failure; the tail of the failing log is printed |
| 3 | Built, not installed: phone unreachable or locked. The app path is printed; ask Adam to unlock the phone and rerun |
| 4 | Installed, but the Omi process is not running after launch (startup crash or locked phone) |

## What it handles, and why

- **Canonical config.** The Firebase options, `GoogleService-Info.plist` files,
  `LocalSigning.xcconfig`, and `.dev.env` are gitignored and per-worktree, so a tree's
  own copies go stale or wrong without warning (this bit twice). The script always copies
  them from `~/dev/omi-local-config/` (override with `OMI_LOCAL_CONFIG`), skipping any
  file the tree tracks, and fails unless the iOS Firebase project is `based-hardware`
  with bundle `com.adam.omi.dev`. A wrong project builds fine and then shows "Omi could
  not start" on the phone.
- **Prod flavor.** The `dev` flavor forces the `local_dev` profile (local emulator and
  backend), so only `prod` reaches `api.omi.me`.
- **Pinned Flutter** from `.github/workflows/mobile-app-checks.yml`, via fvm (installed
  if missing). Flutter is not on the shell PATH.
- **UTF-8 locale.** CocoaPods crashes under an empty locale.
- **pod install only when needed** (`Podfile.lock` differs from `Pods/Manifest.lock`),
  retried once with `--repo-update` for transient CDN errors. It can rewrite a stale
  upstream `app/ios/Podfile.lock`; never commit that change.
- **Env codegen.** A full `build_runner build` regenerates the gitignored
  `lib/env/*.g.dart`. A `--build-filter` run deletes tracked outputs and breaks the build.
- **xcodebuild** with `-xcconfig ios/Flutter/LocalSigning.xcconfig` (otherwise it signs
  BasedHardware's App ID) and `generic/platform=iOS` (a device destination times out
  mounting the disk image). The Watch app is embedded; physical Watch installation
  and launch still require separate verification.

## Verifying

The script verifies the launch itself: it reads the installed app's container from
`devicectl device info apps` and requires a running `Runner` process from that container
in `devicectl device info processes`, so a stale process from an older install does not
count. Screenshots are not a launch check (one showed Settings while Omi ran in the
background), and the device console stays silent for the "Omi could not start" screen.

For the physical Watch, verify its own embedded provisioning profile includes its
UDID, Developer Mode is enabled on the Watch, and its built `Info.plist` contains a
nonempty `NSMicrophoneUsageDescription`. The phone's permission description does not
cover the Watch app. A missing Watch description caused a TCC recording-start crash on
October 13, 2026. The Watch recording test covers this privacy requirement.

If direct Mac-to-Watch access fails, the companion iPhone can still install the app
through its Watch app and expose Watch crash reports under `systemCrashLogs` in
`devicectl device info files`. Look for `ProxiedDevice-*/.../omiWatchApp-*.ips` and
copy the report with `devicectl device copy from`, preserving the device's logs.
Confirm actual installation rather than only the placeholder, then verify launch.
The companion can retain an older Watch binary when both bundles have the same
`CFBundleVersion`, even after reinstalling the phone app. If the Watch payload
changed, use a newer Watch build number in a fresh canonical-config copy via
`CURRENT_PROJECT_VERSION[sdk=watchos*]` in `LocalSigning.xcconfig`, then rerun the
canonical installer with `OMI_LOCAL_CONFIG`. Preserve the original configuration
and recordings. With the phone wired, bounded `appconduitd` logs can distinguish
`Finished placeholder install` from `Finished install` and report
`watchKitAppExecutableHash`; compare that hash with the built Watch executable.
End temporary Device Hub screen sessions afterward; an active session suppressed
the iPhone's onscreen keyboard even with keyboard capture off during this recovery.

## Watch Idea and Task capture

The Watch's Idea and Task buttons record its own microphone to a short AAC file
(up to five minutes), then transfer it to the iPhone's durable inbox. After one-time account setup, recording starts entirely on the Watch, even
when the phone is unavailable. Watch Connectivity delivers files in the background;
a dedicated Flutter entrypoint restores auth and saves them without opening UI.
The native coordinator admits one worker engine at a time and requests additional
iOS processing windows for deferred saves. iOS controls background scheduling,
so offline or delayed delivery remains visibly pending. These explicit recordings
do not finish or replace an active pendant conversation.

Idea uses the existing Ideas conversation folder, shared with the Mac lightbulb.
Task creates a manual action item. Neither button writes a memory. The phone
checkpoints transcription and conversation identity before subsequent writes;
stable capture IDs make destination retries idempotent. Only the confirmed task
identity or a read-back of the completed conversation in Ideas earns a Saved
receipt. Transient failures retry automatically with backoff. Failed recordings remain
on-device and can be retried from the Watch
under the original account. Audio is retained locally, including after saving.
Watch rows distinguish waiting for the phone, measured file-transfer progress,
upload/transcription, destination save, automatic retry after an error, and saved.
Only errors offer Retry. Progress is sent at the active recording's checkpoints;
receipts carry timestamps so delayed background messages cannot rewind the UI.
Stale activity becomes waiting, and the ten latest confirmed saves remain visible.
Startup/timer drains acquire the native background lease too, so leaving the
phone app does not interrupt a retry immediately.

Core implementation: `app/ios/WatchCapture/WatchCaptureStore.swift`,
`app/ios/Runner/WatchCaptureHost.swift`, `app/ios/omiWatchApp/WatchQuickCapture.swift`,
and `app/lib/services/watch/`. The shared Pigeon interface lives in
`app/lib/pigeon_interfaces.dart`; regenerate all three platform outputs together.
The phone converts retained AAC `.m4a` recordings to PCM `.wav` before upload.
The hosted multipart transcription route rejects `.m4a`; renaming it to `.mp4`
also prevents WAV duration measurement and can overcharge the duration budget.
If a capture stays pending, inspect its phone inbox JSON status/error/checkpoints
before investigating Watch pairing. Delivered audio with `transcription` errors
proves transport succeeded. Never remove the original to retry a failed upload.
Verify native persistence/receipts with
`ruby app/ios/test/watch_recording_presentation_test.rb` and destination/retry
behavior with `cd app && bash test.sh test/services/watch` in a hermetic test
checkout, before applying the physical-device configuration above.

## Failures only Adam can fix

- **Locked phone** (exit 3 or 4): ask Adam to unlock it and keep it awake.
- **"No Accounts"** from xcodebuild: a fresh Xcode install drops the Apple ID. Adam adds
  it in Xcode > Settings > Accounts; there is no headless path.
- **Missing `~/dev/omi-local-config/`**: recreate it from a checkout whose installed build
  works, then check the expected values in its README.
