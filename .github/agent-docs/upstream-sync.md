# Upstream sync, release, and device deployment (fork)

Use this procedure to integrate fresh `BasedHardware/Omi` source into
`adamlsneed/omi`, preserve fork capabilities, verify and merge, then publish the
applicable desktop/Homebrew release and deploy Mac, iPhone, and Apple Watch apps.
Read `fork-rules.md`, the affected component guides, `desktop/macos/RELEASE.md`,
and `ios-install.md` before their respective steps.

## Standing conflict and recovery policy

Adam authorized autonomous conflict resolution and repair on October 13, 2026.
Prefer current BasedHardware behavior for ordinary product choices. Preserve
capabilities the fork added and fixes whose underlying defect remains upstream,
adapting them to upstream's structure. When upstream supplies an equivalent,
replace the fork implementation and verify the capability still works. Resolve
hunk by hunk, never blanket-overwrite a file carrying unrelated fork features.

A failed check starts diagnosis and repair, not an automatic handoff. Run the
relevant checks again after fixing the cause. Bound retries for transient
infrastructure failures. Never bypass hooks, weaken assertions, count a failure
as passed, force-push, rewrite published history, or push directly to main.
Merge through a fork PR with a regular merge commit only after verification.
Backend files follow the mirror policy and sole approved test exception in
`fork-rules.md`; never deploy a fork backend or send changes to BasedHardware.

If an external prerequisite cannot be supplied by the agent, finish independent
work, preserve artifacts and recovery evidence, and report the exact missing
prerequisite. An unreachable or locked device does not erase successful work on
other devices. A built bundle is not an installed or verified application.

## 1. Inspect and fetch

Inspect existing sync PRs/issues, release assets, installed source revisions,
local changes, and task artifacts before starting. Resume relevant unfinished
work rather than creating duplicates or stopping at an old review issue.

```bash
git fetch origin --no-tags
git fetch upstream --no-tags
gh issue list -R adamlsneed/omi --label upstream-sync --state open
gh pr list -R adamlsneed/omi --state open
```

Inspect the latest published upstream desktop and mobile releases read-only.
Record their separate versions and freeze one freshly fetched upstream commit
for this run. Sync `upstream/main`, checking that it includes the intended release
source. Fetch needed fork release tags explicitly. Do not force-replace a local
tag or push upstream tags, which can trigger publishing workflows.

If upstream is already included in `origin/main`, skip the merge; still finish
any authorized pending release or device deployment. Do not manufacture a new
version when the same desktop source is already released.

## 2. Prepare the task worktree and merge

Use a managed task worktree based on current `origin/main` with a `codex/` branch.
Preserve unrelated local edits and existing recovery artifacts. Run `make setup`
in a new worktree to install hooks and its backend Python environment. Use that
worktree's `backend/.venv/bin` for Python-based hooks. Read current toolchain pins
rather than copying a version from an old run. The desktop release script manages
its own Node/npm runtime; component checks need the documented toolchain on PATH.

Inventory divergence with the fork feature audit, manifests, tests and Git diff.
Record the merge base and exact upstream SHA before merging:

```bash
MB=$(git merge-base origin/main upstream/main)
UPSTREAM_SHA=$(git rev-parse upstream/main)
git merge --no-ff --no-edit "$UPSTREAM_SHA"
```

Merge, never rebase published sync work. Preserve the selected SHA for subsequent
mirror checks even if another process fetches newer upstream commits.

## 3. Resolve conflicts and preserve fork additions

- Keep both unrelated changes; move fork features into upstream's new structure.
- Follow upstream removals/renames when the fork touched a file incidentally.
- Keep both localization key sets; regenerate generated files using current tools.
- Apply the standing policy to product conflicts without waiting for Adam.
- Keep `backend/` byte-equivalent to the selected upstream commit apart from the
  exact approved test-only exception in `fork-rules.md`. If formatting
  or hooks change that mirror, fix the fork tooling responsible before committing;
  do not amend with `--no-verify` or edit upstream backend files to satisfy it.
- Remove superseded fork implementations, tests, audit entries and docs together
  only after confirming the upstream equivalent covers the original requirement.

Preserve Watch Idea/Task capture and the Mac Ideas shortcut. Their destinations,
background delivery, WAV conversion, ownership, idempotency, progress and saved
receipt requirements are owned by `ios-install.md`, under "Watch Idea and Task
capture". A foreground-iPhone requirement is a regression. Ideas use the existing
Ideas folder, not memories; pendant recording remains independent.

Document meaningful resolutions and their verification in the PR. Commit a clean
resolved merge and continue, repairing integration fallout as needed.

## 4. Verify

Use the component guides for changes in the actual merged diff, including fork
adaptations, not only the upstream range. Always run:

```bash
./scripts/fork-feature-audit.sh
git diff --quiet "$UPSTREAM_SHA" -- backend/ \
  ":(exclude)backend/tests/unit/test_edit_tools_resilience.py"
# Verify the excluded test against the hook's approved blob, or restore upstream
# when its equivalent repair lands. All production backend bytes must match.
git diff --check origin/main HEAD
make preflight
```

Run the documented Swift, Flutter, native iOS, firmware, web or other component
checks for the affected paths. For Watch changes, include the native recording
and Flutter worker tests listed in `ios-install.md`. Verify generated outputs
without committing incidental CocoaPods lockfile or local signing changes.

If an apparent upstream failure needs attribution, reproduce it in an isolated
checkout of the selected upstream revision. Attribution does not turn a failure
into a pass. Repair the fork integration or identify a genuine external blocker.

Batch fixes and local verification before pushing. A new push cancels in-flight
CI. Avoid repeating broad checks after an unchanged successful run unless a new
failure or source change justifies it. Do not set a global `TZ`; it can leak into
the launched Mac app and display incorrect local times.

## 5. Review workflow and signing changes

Inspect new/changed workflows, disabled-workflow copies, entitlements, bundle IDs,
signing profiles, release scripts, Sparkle configuration and appcast changes.
Resolve compatibility issues autonomously while retaining the fork's identities,
hosted services and release destinations. These changes require careful review
and verification, not an automatic stop for Adam.

Preserve individually disabled Actions workflows when restoring globally paused
Actions. Keep cloud/backend deploy workflows disabled. Classify new workflows by
behavior as well as names, including deployment commands and added secret access.
After merge, immediately disable newly introduced upstream deploy workflows and
cancel any triggered run; verify `disabled_manually` through the Actions API.
Do not release while a deployment workflow remains unintentionally enabled.
The fork must never receive upstream deployment credentials.

## 6. Push, PR, verify final CI, and merge

Prepare a PR body outside the repository, covering the exact upstream range and
versions, retained/replaced fork capabilities, conflict resolutions, and actual
verification. Use the metadata checks without unnecessarily rerunning all tests:

```bash
scripts/pr-preflight --suggest
scripts/pr-preflight --metadata-only --pr-body-file /tmp/omi-pr-body.md
```

Set `OMI_PR_BODY_FILE` to that file for the normal pre-push gate. The fork's
`PRE_PUSH_SKIP_BACKEND_UNIT_TESTS=1` matches its backend CI policy; it does not skip
mirror verification or other checks. Push the task branch normally. Create or
update a PR explicitly against `adamlsneed/omi`, never BasedHardware, and attach
it to the task. Use current CI diagnostics for the final PR head. Fix failures
and rerun affected checks before merging; never merge while required checks are
pending or failed. Review changed scope and unresolved findings as well.

Merge with `gh pr merge <PR> -R adamlsneed/omi --merge`. Close obsolete sync issues
only after their causes are resolved. Fetch origin and fast-forward the primary
checkout's main, preserving unrelated local work. Keep needed worktree artifacts
until releases and device deployment finish.

## 7. Desktop and Homebrew release

Compare merged desktop application source against the latest published fork
release, excluding documentation, tests and changelog-only changes. If it is
already released, verify and reuse the existing release. Otherwise follow
`desktop/macos/RELEASE.md` from clean, up-to-date primary main:

```bash
cd desktop/macos && ./release.sh --bump
```

Check the `omi-notary` credential before expensive work and again before
publication; a locked login keychain can hide it while ordinary signing works.
Allow the release script's documented notarization window. Verify GitHub ZIP
bytes, notarization, Homebrew cask version/checksum and signed Sparkle appcast
agree. Finish and attach the changelog PR if automatic consolidation did not.

After any partial failure, inspect published assets and local logs first. Repair
and resume only missing steps. Do not blindly rerun the publisher or replace a
published artifact with different bytes. Preserve exact hashes and source
provenance so a later run can resume safely.

## 8. Redeploy Omi Dev

Use `scripts/fork/redeploy-omi-dev.sh` from merged primary main. Preserve an older
rollback backup before its usual backup location is replaced. Verify the intended
signing identity, hosted-service configuration, source revision and running
process. Never stop or replace production Omi or Omi Beta.

Read the script's exit diagnostics. A capture-probe timeout alone does not prove a
permission failure: inspect idle/analysis gates and newly created capture times
before changing permissions. Keep automated verification separate from user
confirmation. Repair a failed deployment or report its exact remaining blocker.

## 9. Build and deploy iPhone and physical Watch

Follow `ios-install.md` and use only `scripts/fork/ios-install.sh`. Use current
canonical local configuration. When a Watch signing override is needed, copy that
configuration to a fresh task-owned directory and pass it with `OMI_LOCAL_CONFIG`;
never reuse stale Firebase settings or commit local credentials/configuration.

Before installing, validate the embedded Watch signature, its profile's device
coverage, and its own microphone permission description. Verify iPhone install
and launch against the new app container. Verify physical Watch installation,
launch and recording separately. The phone receiving an embedded Watch bundle or
completing a placeholder install is insufficient. Where available, compare the
actual installed Watch binary hash with the build; otherwise record explicit
physical-device/user evidence for the new UI and behavior.

Verify Idea and Task saves with Omi in the iPhone's background, including truthful
pending/progress messages and destination-confirmed Saved receipts. Use the
inbox/checkpoint diagnostics in `ios-install.md` before troubleshooting pairing.
Retain original recordings and do not create duplicate destinations on retries.
Keep Device Hub phone screen sessions disconnected, since they can suppress the
phone's keyboard. Do not unpair or reset devices to recover direct Watch access.

If installation succeeded but the phone was locked at launch, resume launch
verification instead of rebuilding. Reuse an existing signed artifact only after
verifying component source equivalence with merged main; matching version strings
alone are insufficient. Do not claim cold-start or background scenarios that were
not actually tested.

## Finish and recovery notes

Report the selected upstream revision/releases, merged PR, verification, retained
fork features, published desktop version and Homebrew/appcast result, installed
Mac source revision, and separate iPhone/Watch installation and behavior results.
Distinguish completed, built but not installed, and externally blocked work.

Retain signed bundles, hashes, source provenance and concise recovery notes before
cleaning up task-owned worktrees. Use the managed archive operation for managed
worktrees. Preserve needed ignored build artifacts separately; never discard
uncommitted work or remove a preexisting checkout to save space. Update the
scheduled task's notes with recurring lessons and the latest checkpoint, keeping
technical procedures in their owning guide.
