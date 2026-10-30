# Fork rules (adamlsneed/omi)

This repository is a soft fork of BasedHardware/Omi that tracks upstream one way:
upstream changes are merged in regularly; nothing flows back.

- Never deploy fork-owned backends (Python, Rust, pusher, agent-proxy, GKE). The fork
  runs against BasedHardware's hosted services; `backend/` production code is pulled as an exact mirror
  and never deployed. The approved test-only exceptions are recorded below. Upstream workflows that deploy on push to `main` live in
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

The pre-commit hook and CI verify backend bytes against the integrated upstream
revision using `.github/scripts/fork_policy.py`, preserving upstream formatting.
Adam approved these exact test-only exceptions, with upstream and fork blobs
pinned in that verifier:

- October 25, 2026: `backend/tests/unit/test_edit_tools_resilience.py` uses the
  fixture-scoped `stub_modules` helper; all 15 original test bodies are unchanged.
- October 30, 2026: `backend/tests/unit/test_task_integrations_sanitization.py`
  removes an unnecessary global Jinja2 mock; all six test bodies are unchanged.
- October 30, 2026: `backend/tests/unit/test_episode_boundary_evidence.py` freezes
  the fixture and store clocks together, preserving all 22 test cases and their
  assertions after the original timestamp ages beyond retention.
- October 30, 2026: `backend/config/task_intelligence_sources_v1.json` registers
  the Watch task writer. Only tests consume this source inventory; no production
  backend reader consumes it.

Every other backend byte must match upstream. A changed exception blob fails
verification. Retire each exception when upstream supplies equivalent behavior;
do not expand these exceptions without explicit authorization.

The logging-entrypoint guard runs unchanged against disposable snapshots with
archived deployment definitions restored locally. Its first adoption uses the
imported migration inventory when the fork base predates that
schema; subsequent runs compare with the fork base. Fixtures retain the logging
and missing-workflow rejection checks. This never enables a GitHub workflow.

The nightly calls backend test workflows even when their standalone Actions entry
is disabled. Those jobs restore archived workflow definitions only inside the
runner's disposable checkout, limited to definitions still present in the
integrated upstream revision, preserving the upstream test assertions without
publishing or enabling a deployment workflow. Backend formatting in CI uses the
same blob-pinned mirror verifier as pre-commit (`.github/scripts/fork_policy.py`).
Lifecycle baseline exemptions require exact upstream file bytes. Overdue feature
flag reviews are reported as upstream-owned warnings only while the entire
registry matches the integrated upstream revision; fork registry edits retain
the normal review deadline gate. Schema, coverage and rendered-doc checks remain
mandatory in both cases. CI fetches upstream ancestry to identify the integrated
revision rather than treating a newer upstream head as the mirror baseline.
