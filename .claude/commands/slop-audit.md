---
description: Audit fork divergence from upstream omi for AI-generated slop (read-only, writes a findings report)
argument-hint: "[app|desktop|omi|all]  (default: all)"
allowed-tools: Read, Grep, Glob, Bash(git:*)
---

Audit my divergence from upstream BasedHardware/omi for "AI slop": cruft that
accumulates from agent-written code without changing what features do. This is a
READ-ONLY audit. Do not edit any code. Produce a report and stop.

Target area: $ARGUMENTS  (if empty, audit all of app/, desktop/, omi/)

backend/ is upstream and out of scope. I run against BasedHardware's hosted
backend, so never read findings into, modify, or "clean up" anything in backend/.

Scope to my delta from upstream, not the whole repo:
1. git remote get-url upstream || git remote add upstream https://github.com/BasedHardware/omi.git
2. git fetch upstream
3. git diff --stat $(git merge-base upstream/main HEAD)..HEAD
4. Restrict to changed files under the target area(s). Ignore generated files,
   lockfiles, build output, and vendored dependencies.

For each changed area, read the diff plus surrounding code and look for:
- Narration comments / docstrings that restate the code; redundant or stale comments.
- Dead code: unused functions, imports, variables, params, unreferenced files,
  commented-out blocks, leftover debug logging (print / debugPrint / NSLog / printk).
- Duplicated logic reimplementing something already in the codebase, framework, or stdlib.
- Reinvented upstream: local code that duplicates a feature or fix BasedHardware now
  ships natively (check this especially right after an upstream sync). Flag as a
  candidate to drop in favor of upstream's version.
- Premature abstraction: wrappers, managers, single-impl interfaces, unused flags/params.
- Defensive cruft: error-swallowing try/catch, redundant null checks, impossible-state validation.
- Inconsistency with surrounding-file and upstream conventions: naming, error
  handling, logging, Flutter state-management patterns, Swift idioms, firmware patterns.
- Misleading, hedgy, or verbose names and redundant prefixes.
- Doc / comment / README drift versus actual behavior.
- Test slop: tautological tests, mock-only assertions, tests that assert nothing.

For each finding record: file:line, category, one-line description, severity
(cosmetic / maintainability / correctness-risk), proposed change. Group by area.
Write to docs/slop-audit-YYYY-MM-DD.md and STOP for my review.

Never propose a change that alters runtime behavior or removes a feature; flag
those as questions instead.
