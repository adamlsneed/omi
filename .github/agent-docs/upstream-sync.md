# Upstream sync and release procedure (fork)

The procedure every agent (Claude, Codex, others) follows to merge `BasedHardware/Omi`
`upstream/main` into `adamlsneed/omi` and ship the desktop build. It runs unattended:
it never resolves a conflict, never merges a PR that needs review, and never retries a
failed release. Background, conflict-resolution rules, and the backend mirror policy
live in `docs/developer/upstream-sync-and-backend-policy.mdx`.

Every run ends with exactly one of these lines:

- `Merged, released vX.Y.Z`
- `Merged, no desktop changes`
- `Needs review: <issue URL>`
- `Conflict: <issue URL>`
- `Nothing to sync.`

After a `Merged, ...` line, add `Disabled workflows: <paths>` if step 6 disabled any.

Whatever the outcome (including a Needs review, a failed command, or an aborted run),
the last action of every run that created the sync worktree is removing it, since a
desktop build there is about 20 GB. Run from the primary checkout:

```bash
git worktree remove --force "$WT"; git worktree prune
git branch -d "$BR" || echo "kept unmerged local branch $BR"
```

Use `-d`, never `-D` (denied on purpose to protect real branches). If `-d` refuses
because the branch is unmerged (a Needs review or failed run), log it and move on; the
pushed branch or the next run covers it.

## Prerequisites

One-time repository setup (already done unless a step below fails):

- Issues enabled on `adamlsneed/omi`, with an `upstream-sync` label.
- The inherited `GitHub Issue Sync` workflow (`.github/workflows/main.yml`) disabled in
  the Actions settings. It fires on every issue opened or labeled and needs a
  `PROJECT_TOKEN` the fork lacks.
- Local git config: `rerere.enabled=true`, `rerere.autoupdate=true`,
  `merge.conflictstyle=zdiff3`.
- "Always Allow" granted to `/usr/bin/security` on the Sparkle signing key (release.sh
  reads the key through it, so rebuilt `sign_update` binaries never prompt).
- `FIREBASE_API_KEY` available to release.sh (see `desktop/macos/RELEASE.md`); a
  missing key fails the release.

Per run, on the Mac that holds the signing keys, in a logged-in GUI session (the
login keychain must be unlocked; SSH or launchd sessions cannot reach it). Codex must
run unsandboxed, since the sandbox blocks the keychain and network.

```bash
# npm 10 (npm 12 fails `npm ci` against the committed lockfiles; /tmp is wiped on reboot)
mkdir -p /tmp/npm10
printf '#!/bin/sh\nexec node "$HOME/.npm/_npx/7c24e36c048e2b23/node_modules/npm/bin/npm-cli.js" "$@"\n' > /tmp/npm10/npm
chmod +x /tmp/npm10/npm
export PATH="/tmp/npm10:$HOME/fvm/versions/3.44.5/bin:$HOME/fvm/versions/3.44.5/bin/cache/dart-sdk/bin:$PATH"
npm -v   # must print 10.x
```

`release.sh` sets up Node and this npm 10 wrapper on its own PATH, so step 7 needs no
prefix; the block above is for step 4's `npm ci` checks. If that npx cache entry is gone, `npm install --prefix /tmp/npm10pkg npm@10` and
symlink `/tmp/npm10pkg/node_modules/.bin/npm` into `/tmp/npm10` instead. `bun` must
also be on `PATH` (the push gate runs `web/app/test.sh`).

## 1. Fetch

```bash
git fetch origin --tags
git fetch upstream --no-tags   # upstream tags (omi-cli-v*) can arm fork publish workflows
git merge-base --is-ancestor upstream/main origin/main && echo "Nothing to sync."
```

If upstream/main is already in origin/main, stop with `Nothing to sync.`

If an open issue labeled `upstream-sync` or an open PR from a `sync/upstream-*` branch
already exists, a previous run is waiting on Adam. Do not start another; end with
`Needs review: <that issue URL>`.

```bash
gh issue list -R adamlsneed/omi --label upstream-sync --state open
gh pr list -R adamlsneed/omi --state open --search "head:sync/upstream-"
```

## 2. Merge

```bash
DATE=$(date +%Y%m%d)
BR=sync/upstream-$DATE
WT="$(cd .. && pwd)/omi-sync-$DATE"
MB=$(git merge-base origin/main upstream/main)   # last synced upstream commit
git worktree add -b "$BR" "$WT" origin/main
git -C "$WT" merge --no-ff --no-edit -m "Merge upstream BasedHardware/omi into $BR" upstream/main
```

Merge, never rebase. Do not create backup branches; the PR is the safety net.

## 3. Conflict: brief and stop

If the merge reports any conflict (including ones rerere resolved from a recorded
resolution), resolve nothing. Write the brief, abort, file it, stop.

```bash
git -C "$WT" diff --name-only --diff-filter=U   # conflicted files
git -C "$WT" rerere status                      # files rerere already has a resolution for
```

For each conflicted file, the brief gives:

- **Upstream changed:** `git log --oneline $MB..upstream/main -- <file>` plus a one or
  two sentence summary of `git diff $MB upstream/main -- <file>`.
- **Fork changed:** the same against `origin/main`, naming the fork feature involved
  (see `scripts/fork-feature-audit.sh` and the runbook's Current Fork Notes).
- **Suggested resolution:** per the runbook's Conflict Resolution Rules (backend always
  takes upstream exactly; l10n ARBs combine both key sets; generated files take upstream
  and regenerate; if upstream fixed the same issue, drop the fork copy). Never suggest a
  wholesale `--theirs` for a file that carries unrelated fork work: it deletes every fork
  hunk in the file, not just the conflicting one.
- Whether rerere has a recorded resolution for it.

Then:

```bash
git -C "$WT" merge --abort
git worktree remove "$WT" && { git branch -d "$BR" || echo "kept local branch $BR"; }
gh issue create -R adamlsneed/omi --label upstream-sync \
  --title "Upstream sync conflict ($DATE, ${MB:0:10}..$(git rev-parse --short=10 upstream/main))" \
  --body-file <brief.md>
```

End with `Conflict: <issue URL>`.

## 4. Verify (clean merge)

Scope by what upstream touched: `git diff --name-only $MB upstream/main`. Run from the
worktree root. Record every command and result for the PR body. A missing tool is a
failure, not a skip.

Always:

```bash
./scripts/fork-feature-audit.sh                      # every check "ok"
git diff --quiet upstream/main -- backend/           # backend is an exact upstream mirror
git diff --check origin/main HEAD                    # no conflict markers or whitespace damage
```

| Upstream touched | Run |
|---|---|
| `desktop/macos/` Swift | `cd desktop/macos && xcrun swift build --build-tests -c debug --package-path Desktop && ./scripts/run-swift-ci.sh --test` (per-suite processes; plain `swift build` skips tests and plain `swift test` can die silently mid-run) |
| `desktop/macos/agent/` | `cd desktop/macos/agent && npm ci && npm test` |
| `desktop/macos/pi-mono-extension/` | `cd desktop/macos/pi-mono-extension && npm ci && npm test` |
| `desktop/` Rust | `cd desktop && cargo test` |
| `app/` | `cd app && ./test.sh && flutter analyze` (Flutter 3.44.5; analyze must report 0 errors) |
| `app/lib/l10n/` | `cd app && flutter gen-l10n` and confirm no diff |
| `app/ios/` | `ruby app/ios/test/uiscene_lifecycle_adoption_test.rb`, `app_group_identity_test.rb`, `flutter_launch_engine_guard_test.rb` |
| `omi/firmware/` | the idea-capture reservation greps in the runbook's "Files To Check After A Merge" |

Before calling an upstream-owned test failure sync damage, reproduce it on upstream
(`git archive upstream/main <path> | tar -x -C <tmp>`). Either way a failure routes to
Needs review; the brief says which it is.

`make preflight` runs in step 6 with the PR body.

## 5. Needs review triggers

Any one of these routes to Needs review (step 6 opens the PR but does not merge):

- Any check in step 4, `make preflight`, or PR CI fails.
- A new workflow file that does not deploy to cloud infrastructure:
  `git diff --name-only --diff-filter=A $MB upstream/main -- .github/workflows`. New
  deploy workflows (see "Disable new deploy workflows" in step 6) do not trigger this on
  their own; step 6 disables them after the merge.
- A changed deploy or publish workflow: a modified `.github/workflows/` file whose name
  matches `gcp_|deploy|release|publish|helm`, or whose Actions state is
  `disabled_manually` (`gh api --paginate repos/adamlsneed/omi/actions/workflows --jq '.workflows[]|select(.state!="active")|.path'`),
  or an active push/schedule/workflow_run workflow whose diff adds a `secrets.` reference
  (the fork has none; the 2026-09-23 `mobile_internal_build.yml` failure emails).
- Upstream changed a file whose fork copy lives in `.github/disabled-workflows/`, or the
  merge changes anything in that directory: `git diff --name-only origin/main HEAD -- .github/disabled-workflows`
- Entitlements, signing, or notarization config:
  `git diff --name-only origin/main HEAD | grep -E '\.entitlements$|\.mobileprovision$|\.provisionprofile$|ExportOptions.*\.plist$'`,
  or `CODE_SIGN|DEVELOPMENT_TEAM|PROVISIONING_PROFILE|codesign|notar` in the diff of
  `desktop/macos/run.sh`, `desktop/macos/Desktop/Info.plist`, or
  `app/ios/Runner.xcodeproj/project.pbxproj`.
- `desktop/macos/release.sh` or `desktop/macos/scripts/release-appcast.sh` changed.
- Sparkle or appcast settings: `SUFeedURL|SUPublicEDKey|SUEnable|appcast` in the
  `Info.plist` or `run.sh` diff, or the Sparkle pin in `desktop/macos/Desktop/Package.resolved`
  moved.
- Bundle identifiers: `BUNDLE_ID|CFBundleIdentifier|PRODUCT_BUNDLE_IDENTIFIER` in the
  diff of `desktop/macos/run.sh`, `desktop/macos/Desktop/Info.plist`,
  `app/ios/Runner.xcodeproj/project.pbxproj`, or `app/ios/Flutter/*.xcconfig`.

`codemagic.yaml` is out of scope: the fork does not use Codemagic and upstream edits it
every sync. Content triggers read shipping config only; tests and QA scripts that
mention these keys are noise.

## 6. Push, PR, merge

Write the PR body to /tmp/omi-pr-body.md (a scratch file, not in the repo) first, then push with a plain command:

```bash
git -C "$WT" push -u origin "$BR"
```

The repo's Claude settings `env` block sets `PRE_PUSH_SKIP_BACKEND_UNIT_TESTS=1` (matches
fork CI, which does not run upstream's backend unit tests), `TZ=UTC` (avoids a
timezone-dependent upstream web test), and `OMI_PR_BODY_FILE` (pointing at that body
file) for the pre-push hook. Other agents export the same three. Never prefix `git` with variable
assignments or `cd`; use `git -C <path>`.

PR body, modeled on #126: Summary (range `$MB..upstream/main`, commit count, versions),
What's in this sync (categorized upstream features, fixes, and notable changes;
`git log --no-merges --pretty='%s' $MB..upstream/main`), Verification (each command and
result), then the sections `scripts/pr-preflight` asks for:

```bash
scripts/pr-preflight --suggest                   # invariant citations, failure class, line-count exceptions
scripts/pr-preflight --pr-body-file /tmp/omi-pr-body.md    # must pass
make preflight
gh pr create -R adamlsneed/omi --base main --head "$BR" \
  --title "Sync upstream BasedHardware/omi ($DATE, N commits)" --body-file /tmp/omi-pr-body.md
gh pr checks <PR> -R adamlsneed/omi --watch
```

Never open anything against BasedHardware. `gh pr create` must name `-R adamlsneed/omi`.

**Needs review:** if any step 5 trigger fired, leave the PR open and file an issue that
links it and lists exactly what needs Adam's eyes (failing command with the relevant
output, or the trigger with file paths and the diff hunk). End with
`Needs review: <issue URL>`.

**Otherwise:**

```bash
gh pr merge <PR> -R adamlsneed/omi --merge       # merge commit, never squash
```

Then fast-forward the primary checkout's `main` (it must be clean on tracked files) and
remove the sync worktree.

**Disable new deploy workflows.** Fork rules keep upstream's cloud deploys off. A new
workflow counts as a deploy if its name matches `gcp_|deploy|helm|gke|cloud.?run` or its
body matches `gcloud|google-github-actions/|kubectl|helm |firebase deploy|aws-actions/|terraform apply`:

```bash
for f in $(git diff --name-only --diff-filter=A $MB upstream/main -- .github/workflows); do
  if basename "$f" | grep -qiE 'gcp_|deploy|helm|gke|cloud.?run' \
     || grep -qE 'gcloud|google-github-actions/|kubectl|helm |firebase deploy|aws-actions/|terraform apply' "$f"; then
    gh workflow disable "$(basename "$f")" -R adamlsneed/omi
    gh run list -R adamlsneed/omi --workflow "$(basename "$f")" --json databaseId,status \
      --jq '.[]|select(.status!="completed").databaseId' | xargs -n1 gh run cancel -R adamlsneed/omi
  fi
done
gh api --paginate repos/adamlsneed/omi/actions/workflows --jq '.workflows[]|[.path,.state]|@tsv'
```

Each one must show `disabled_manually`; list them in the run's `Disabled workflows:`
line. The merge push can start one before it is disabled; the fork has no deploy
secrets, so that run fails without deploying, and the loop cancels it if still running.
If a disable fails, file an `upstream-sync` issue and end with `Needs review: <issue URL>`
without releasing.

## 7. Release (desktop changed)

```bash
LAST=$(git ls-remote --tags origin 'desktop-fork-v*' | sed -E 's#.*refs/tags/##; s/\^\{\}$//' | sort -V | tail -1)
git diff --quiet "$LAST" origin/main -- desktop/macos \
  ':!desktop/macos/changelog' ':!desktop/macos/CHANGELOG.json' \
  ':!desktop/macos/Desktop/Tests' ':!desktop/macos/e2e' ':!*.md'
```

Exit 0: end with `Merged, no desktop changes`.

Otherwise follow `desktop/macos/RELEASE.md`, from the primary checkout on up-to-date,
clean `main` (the build uses that tree):

```bash
cd desktop/macos && ./release.sh --bump
```

A normal run takes about 15 to 25 minutes. release.sh itself fails if notarization is
still in Apple's queue after 90 minutes; treat a whole run past 2 hours as a failure.

The changelog step is part of release.sh: in a temporary worktree on `origin/main`
(removed afterward), it folds `changelog/unreleased/*.json` into
`changelog/releases/<version>.json` and auto-merges a `chore/desktop-changelog-<version>`
PR. It never switches the primary checkout's branch. If it prints `WARNING: changelog
consolidation failed`, do it by hand in a clean worktree: `python3
.github/scripts/desktop-changelog.py consolidate --version <v> --write` from
`desktop/macos`, commit, push, PR, merge with a merge commit.

Confirm all three updated:

```bash
V=<version>
gh release view "desktop-fork-v$V" -R adamlsneed/omi --json assets --jq '.assets[].name'   # omi-desktop-$V.zip
gh api repos/adamlsneed/homebrew-omi/contents/Casks/omi.rb --jq .content | base64 -d | grep "version \"$V\""
gh api repos/adamlsneed/homebrew-omi/contents/appcast.xml --jq .content | base64 -d | grep "<sparkle:version>$V<"
```

If release.sh exits non-zero, runs past the time limit, or any confirmation fails: file
an `upstream-sync` issue with the failing step and the last 50 lines of output, and end
with `Needs review: <issue URL>`. Do not rerun release.sh: a partial run may already have
published the GitHub release or the cask, and a rerun rebuilds with a different sha256.

Otherwise end with `Merged, released v$V`.
