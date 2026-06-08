# Desktop fork releases (Homebrew)

Fork-owned, signed + notarized desktop releases distributed via a Homebrew cask.
This is independent of BasedHardware's Codemagic/Sparkle pipeline; it uses your own
`Developer ID Application: Adam Sneed (66K48S8RD4)` cert and your own tap.

The app keeps the existing bundle id (`com.omi.desktop-dev`, "Omi Dev"), so your
auth/sign-in state and BasedHardware backend access are unchanged — only the build
is signed/notarized/distributed differently.

## One-time setup
1. Store notarization credentials as a keychain profile named `omi-notary`:
   ```
   xcrun notarytool store-credentials omi-notary \
     --apple-id <your-apple-id-email> \
     --team-id 66K48S8RD4 \
     --password <app-specific-password>
   ```
   App-specific password: appleid.apple.com → Sign-In & Security → App-Specific Passwords.
2. `gh auth status` must be authenticated (for publishing the release + cask).
3. Tap repo already exists: https://github.com/adamlsneed/homebrew-omi

## Cut a release
```
cd desktop
./release.sh <version>        # e.g. ./release.sh 0.1.0
```
This builds `-c release`, signs with `Omi-Release.entitlements` (omits the
`get-task-allow` / `applesignin` entitlements that previously blocked notarization),
notarizes + staples, publishes a GitHub Release on `adamlsneed/omi` (tag
`desktop-fork-v<version>`), and updates the cask in the tap.

Smoke-test without shipping:
```
SKIP_NOTARIZE=1 SKIP_PUBLISH=1 ./release.sh 0.0.1-test   # build + sign only
SKIP_PUBLISH=1 ./release.sh 0.1.0                         # + notarize, no publish
```

## Install / update (each Mac)
```
brew install --cask adamlsneed/omi/omi
brew upgrade                                  # pulls new versions
```
Schedule `brew upgrade` via launchd if you want hands-off updates.

## Notes
- Auto-update via Sparkle stays off for this bundle (upstream's dev-build policy);
  Homebrew is the update path. No upstream source was modified.
- `release.sh` mirrors `run.sh`'s bundle assembly; keep them in sync if `run.sh`'s
  assembly changes on an upstream pull.
- The bundled `.env` is inherited from the installed app when the gitignored
  `.env.app*` aren't present, so auth config carries over.
