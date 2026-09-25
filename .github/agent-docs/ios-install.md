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
  mounting the disk image). The watch app is embedded, so one install covers the watch.

## Verifying

The script verifies the launch itself: it reads the installed app's container from
`devicectl device info apps` and requires a running `Runner` process from that container
in `devicectl device info processes`, so a stale process from an older install does not
count. Screenshots are not a launch check (one showed Settings while Omi ran in the
background), and the device console stays silent for the "Omi could not start" screen.

## Failures only Adam can fix

- **Locked phone** (exit 3 or 4): ask Adam to unlock it and keep it awake.
- **"No Accounts"** from xcodebuild: a fresh Xcode install drops the Apple ID. Adam adds
  it in Xcode > Settings > Accounts; there is no headless path.
- **Missing `~/dev/omi-local-config/`**: recreate it from a checkout whose installed build
  works, then check the expected values in its README.
