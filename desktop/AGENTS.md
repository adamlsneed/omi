# Desktop (macOS) — agent guide (fork)

Full developer guide: **[`CLAUDE.md`](CLAUDE.md)**. Release/distribution: **[`RELEASE.md`](RELEASE.md)**.

## Build & run (dev, this Mac)
- `cd desktop && ./run.sh` — debug build, installs/launches `/Applications/Omi Dev.app`. Use this to test changes.
- Compile check only: `xcrun swift build -c debug --package-path Desktop` (the `xcrun` prefix is required).

## Releases (read this — common misconception)
This fork does **NOT** auto-release. Upstream's Codemagic/auto-release GitHub
Actions were removed, so **merging `desktop/**` to `main` ships nothing** — it only
lands code. Anything that says "merge triggers a Codemagic release" is stale.

To build + distribute a release:
```
cd desktop && ./release.sh --bump        # patch bump; also --bump minor|major or an explicit version
```
This builds `-c release`, signs with the user's own Developer ID (team `66K48S8RD4`)
+ `Omi-Release.entitlements`, **notarizes** (keychain profile `omi-notary`), publishes a
GitHub Release on `adamlsneed/omi` (tag `desktop-fork-v<version>`), and updates the
Homebrew cask in `adamlsneed/homebrew-omi`. Install/update on a Mac:
`brew install --cask adamlsneed/omi/omi` then `brew upgrade`. See `RELEASE.md` for the
full process (notarization setup, why `Omi-Release.entitlements`, auth/.env handling).

`release.sh` mirrors `run.sh`'s bundle assembly; keep them in sync if `run.sh`'s
assembly changes on an upstream pull.
