---
name: ios-install
description: Build and install the Omi iPhone app (with its embedded Watch app), signed with Adam's development certificate, onto his paired iPhone. Use when asked to build, install, update, or redeploy the iPhone or iOS app.
---

Run `scripts/fork/ios-install.sh` from the repo root or any worktree. Read `.github/agent-docs/ios-install.md` first for options, exit codes, and gotchas.

Do not hand-run the Flutter or xcodebuild steps. The script copies the canonical gitignored config from `~/dev/omi-local-config`, builds the prod flavor, installs with devicectl, and confirms the app process is running on the phone. If the phone is unreachable it reports "built, not installed" and keeps the build.
