# Fork rules (adamlsneed/omi)

This repository is a soft fork of BasedHardware/Omi that tracks upstream one way:
upstream changes are merged in regularly; nothing flows back.

- Never deploy fork-owned backends (Python, Rust, pusher, agent-proxy, GKE). The fork
  runs against BasedHardware's hosted services; `backend/` production code is pulled as an exact mirror
  and never deployed. The sole test-only exception is recorded below. Upstream workflows that deploy on push to `main` live in
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
- Upstream sync and the release that follows it: `.github/agent-docs/upstream-sync.md`.
- Building and installing the iPhone app: `.github/agent-docs/ios-install.md`.
- Redeploying Adam's local Omi Dev Mac app from `main`: `scripts/fork/redeploy-omi-dev.sh`
  (usage and rollback in its header; runs as step 8 of the upstream sync).

The pre-commit hook verifies staged backend bytes against the upstream merge
revision and preserves upstream formatting. Backend formatting runs only outside
the fork. On October 25, 2026, Adam approved one test-only exception:
`backend/tests/unit/test_edit_tools_resilience.py` uses the sanctioned fixture-scoped
`stub_modules` helper while preserving all 15 original test bodies. The hook pins
both upstream and approved fork blobs, rejects every other backend difference,
and fails if either blob changes. Retire the exception when upstream supplies an
equivalent isolated test; do not expand it without explicit authorization.

The logging-entrypoint guard runs unchanged against disposable snapshots with
archived deployment definitions restored locally. Its first adoption uses the
imported migration inventory when the fork base predates that
schema; subsequent runs compare with the fork base. Fixtures retain the logging
and missing-workflow rejection checks. This never enables a GitHub workflow.
