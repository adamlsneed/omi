# Firmware (omi/) — agent guide (fork)

Device firmware: Zephyr, C/C++. The board this fork builds is `omi/firmware/omi/`
(the `devkit/` and `omiGlass/` trees are separate). Most code here is upstream's;
keep fork divergence minimal so upstream pulls stay clean.

## Committing firmware: use --no-verify
The repo's `scripts/pre-commit` hook (symlinked into `.git/hooks/pre-commit`, and
identical to upstream's) runs `clang-format -i` on staged firmware files under
`omi/` and `omiGlass/`. Two consequences:

1. If `clang-format` isn't installed, the hook **fails and blocks the commit**.
2. Upstream's committed firmware is NOT itself clang-format-clean, so when the hook
   runs it reformats the WHOLE staged file (cast spacing, log-line wraps, trailing
   whitespace), churning untouched upstream lines and maximizing merge conflicts.

So commit firmware with **`git commit --no-verify`** to keep files byte-identical to
upstream and avoid re-churn. Make the minimum change that resolves the task; never
reformat a file wholesale.

To tell hook-churn from real changes when auditing: strip all whitespace and compare
to the merge-base. If they match, it is whitespace-only and can be reverted to upstream:
```
git show "$(git merge-base upstream/main HEAD):<path>" | tr -d '[:space:]'  # vs the working file
```

## Feature flags are an app<->device contract
`omi/firmware/omi/src/lib/core/features.h` `OMI_FEATURE_*` bit values must match the
app side in `app/lib/services/devices.dart` (`OmiFeatures`) for every bit the app reads.
Example: mic-gain is `1 << 8` in BOTH. The firmware advertises the bitmask over BLE and
the app reads specific bits, so do NOT renumber a feature bit, and add any new bit on
both sides in the same change. Changing a value breaks the handshake.

## Upstream sync
Pulling BasedHardware/omi is a one-way, fork-specific process. Full runbook:
`docs/developer/upstream-sync-and-backend-policy.mdx`. Never push to upstream.
