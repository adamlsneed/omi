# Fork rules (adamlsneed/omi)

This repository is a soft fork of BasedHardware/Omi that tracks upstream one way:
upstream changes are merged in regularly; nothing flows back.

- Never deploy fork-owned backends (Python, Rust, pusher, agent-proxy, GKE). The fork
  runs against BasedHardware's hosted services; `backend/` is pulled as an exact mirror
  and never deployed. Upstream workflows that deploy on push to `main` live in
  `.github/disabled-workflows/` (see its README) or are disabled in the repository's
  Actions settings.
- Push, merge, and open PRs only against `adamlsneed` remotes, never BasedHardware.
  Upstream sync is one-way: `BasedHardware/Omi` into `adamlsneed/omi`.
- Never push directly to `main`. Land through a PR with a regular merge (never squash);
  once a change is verified, merging needs no per-change approval.
- Desktop releases are cut manually: `cd desktop/macos && ./release.sh --bump`
  (notarized build, GitHub Release on `adamlsneed/omi`, Homebrew cask bump). Merging
  `desktop/**` to `main` ships nothing by itself. Full guide: `desktop/macos/RELEASE.md`.
- `RELEASEWITHBACKEND` is unavailable in this fork.
