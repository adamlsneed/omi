#!/usr/bin/env bash
# Rebuild Adam's local "Omi Dev" (com.omi.desktop-dev) from the checkout this script lives
# in, which must contain current origin/main, and install it on top of the running app.
# Uses the documented deploy path (desktop/macos/run.sh --yolo) with the installed app's
# signing identity, so Screen Recording, Microphone, and other grants carry over.
#
# Keeps one rollback copy in ~/Backups/omi-dev-rollback. If the build, install, or launch
# fails, it restores that copy, relaunches it, and exits non-zero.
#
# If Omi Dev was capturing screens before the deploy, it also waits for the new build to
# write Rewind captures again. A re-signed bundle can silently lose the Screen Recording
# grant; a rollback would not restore it, so that case keeps the new build and exits 3.
#
# Usage: scripts/fork/redeploy-omi-dev.sh
# Exit codes: 0 new build running, 1 failed and rolled back (previous build running),
#             2 precondition failed (nothing changed), 3 new build running but screen
#             capture did not resume (Screen Recording likely needs re-granting),
#             5 failed and rollback also failed.
# Log: /tmp/omi-dev-redeploy.log
set -euo pipefail

APP="/Applications/Omi Dev.app"
BUNDLE_ID="com.omi.desktop-dev"
EXE="$APP/Contents/MacOS/Omi Computer"
BACKUP_DIR="$HOME/Backups/omi-dev-rollback"
BACKUP_APP="$BACKUP_DIR/Omi Dev.app"
LOG=/tmp/omi-dev-redeploy.log
# Rewind storage for com.omi.desktop-dev (DesktopLocalProfile: not a named bundle, so "Omi").
CAPTURE_ROOT="$HOME/Library/Application Support/Omi/users"
CAPTURE_WAIT_SECONDS=300

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DEPLOYING=0

step() { printf '\n==> %s\n' "$*"; }
fail_precondition() { echo "ERROR: $*" >&2; exit 2; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
app_pids() { pgrep -f "^$EXE" || true; }
team_id() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }

wait_for_exit() {
  local i
  for i in $(seq 1 "$1"); do
    [[ -z "$(app_pids)" ]] && return 0
    sleep 1
  done
  return 1
}

# Running check: the process must appear and still be the same PID 15s later, which catches
# the hardened-runtime SIGKILL at launch and early startup crashes.
verify_running() {
  local pid="" i
  for i in $(seq 1 60); do
    pid="$(app_pids | head -1)"
    [[ -n "$pid" ]] && break
    sleep 1
  done
  [[ -n "$pid" ]] || return 1
  sleep 15
  kill -0 "$pid" 2>/dev/null
}

# First Rewind capture file (video chunk or screenshot) matching the extra find predicates.
capture_file() {
  [[ -d "$CAPTURE_ROOT" ]] || return 0
  find "$CAPTURE_ROOT" -type f \( -path '*/Videos/*' -o -path '*/Screenshots/*' \) "$@" 2>/dev/null | head -1 || true
}

restore() {
  echo "Restoring the previous Omi Dev from $BACKUP_APP" >&2
  pkill -f "^$EXE" 2>/dev/null || true
  wait_for_exit 20 || pkill -9 -f "^$EXE" 2>/dev/null || true
  rm -rf "$APP"
  if ditto "$BACKUP_APP" "$APP" && open "$APP" && verify_running; then
    echo "Rolled back: previous Omi Dev is running ($(plist_get CFBundleVersion), $(plist_get OMISourceRevision | cut -c1-10))" >&2
    exit 1
  fi
  echo "ROLLBACK FAILED: Omi Dev is not running. Restore by hand: ditto '$BACKUP_APP' '$APP' && open '$APP'" >&2
  exit 5
}

fail_deploy() {
  echo "ERROR: $*" >&2
  echo "Last lines of $LOG:" >&2
  tail -30 "$LOG" >&2 || true
  restore
}

trap '[[ $DEPLOYING -eq 1 ]] && fail_deploy "interrupted"; exit 130' INT TERM

# release.sh sets up the same toolchain: Node, and npm 10 (npm 12 fails `npm ci` on the
# committed lockfiles).
ensure_toolchain() {
  [ -x "$HOME/.hermes/node/bin/node" ] && PATH="$HOME/.hermes/node/bin:$PATH"
  command -v node >/dev/null 2>&1 || fail_precondition "node not found on PATH or in ~/.hermes/node/bin"
  local npm10_dir=/tmp/npm10 cli="" p
  if [ ! -x "$npm10_dir/npm" ]; then
    for p in "$HOME"/.npm/_npx/*/node_modules/npm; do
      [ -f "$p/package.json" ] || continue
      case "$(node -p "require('$p/package.json').version")" in 10.*) cli="$p/bin/npm-cli.js"; break;; esac
    done
    if [ -z "$cli" ]; then
      npm install --silent --prefix /tmp/npm10pkg npm@10 >&2
      cli=/tmp/npm10pkg/node_modules/npm/bin/npm-cli.js
    fi
    mkdir -p "$npm10_dir"
    printf '#!/bin/sh\nexec node "%s" "$@"\n' "$cli" > "$npm10_dir/npm"
    chmod +x "$npm10_dir/npm"
  fi
  PATH="$npm10_dir:$PATH"
  export PATH
  case "$(npm -v)" in 10.*) ;; *) fail_precondition "npm 10 required, got $(npm -v)";; esac
}

step "Preconditions ($ROOT)"
[[ -d "$APP" ]] || fail_precondition "$APP is not installed; this script only redeploys on top of it"
[[ "$(plist_get CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail_precondition "$APP is not $BUNDLE_ID"
git -C "$ROOT" fetch --quiet origin main
git -C "$ROOT" merge-base --is-ancestor origin/main HEAD \
  || fail_precondition "this checkout does not contain current origin/main; update it first"
ensure_toolchain
old_team="$(team_id "$APP")"
old_identity="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | sed -n 1p)"
[[ -n "$old_team" && -n "$old_identity" ]] || fail_precondition "cannot read the installed app's signing identity"
old_version="$(plist_get CFBundleVersion), $(plist_get OMISourceRevision | cut -c1-10)"
echo "current: $old_version, signed by $old_identity ($old_team)"

step "Rollback copy -> $BACKUP_APP"
mkdir -p "$BACKUP_DIR"
rm -rf "$BACKUP_APP.tmp"
ditto "$APP" "$BACKUP_APP.tmp"
rm -rf "$BACKUP_APP"
mv "$BACKUP_APP.tmp" "$BACKUP_APP"

# Only a build that was capturing before the deploy is expected to capture after it; a locked
# screen or capture switched off writes nothing either way.
captured_before="$(capture_file -mmin -10)"

step "Quit Omi Dev"
DEPLOYING=1
if [[ -n "$(app_pids)" ]]; then
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  if ! wait_for_exit 30; then
    echo "did not quit within 30s; sending SIGTERM"
    pkill -f "^$EXE" || true
    wait_for_exit 15 || fail_deploy "Omi Dev did not exit"
  fi
fi

capture_marker="$(mktemp /tmp/omi-dev-redeploy-marker.XXXXXX)"

step "Build and install (run.sh --yolo --full --no-wait; log: $LOG)"
start=$SECONDS
# A linked worktree otherwise deploys to an isolated omi-<worktree> bundle and port.
export OMI_APP_NAME="Omi Dev" OMI_AUTOMATION_PORT=47777 OMI_SIGN_IDENTITY="$old_identity"
# run.sh resolves agent/ and other inputs relative to its working directory.
if ! (cd "$ROOT/desktop/macos" && ./run.sh --yolo --full --no-wait) >"$LOG" 2>&1; then
  fail_deploy "run.sh failed"
fi
echo "run.sh done in $((SECONDS - start))s"

step "Verify"
[[ "$(plist_get CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail_deploy "installed bundle id is not $BUNDLE_ID"
[[ "$(team_id "$APP")" == "$old_team" ]] || fail_deploy "signing team changed; permissions would not carry over"
verify_running || fail_deploy "Omi Dev is not running after launch"
DEPLOYING=0

new_rev="$(plist_get OMISourceRevision)"
[[ "$new_rev" == "$(git -C "$ROOT" rev-parse HEAD)" ]] || echo "WARNING: installed revision $new_rev is not HEAD"

step "Verify screen capture resumed"
if [[ ! -d "$CAPTURE_ROOT" ]]; then
  echo "WARNING: skipped: $CAPTURE_ROOT does not exist; Omi Dev's Rewind storage has moved, update CAPTURE_ROOT"
elif [[ -z "$captured_before" ]]; then
  echo "skipped: no Rewind captures in the 10 minutes before the deploy (capture off, screen locked, or idle)"
else
  waited=0
  # Birth time, not mtime: startup recovery rewrites old chunks without Screen Recording.
  until [[ -n "$(capture_file -newerBm "$capture_marker")" ]]; do
    if (( waited >= CAPTURE_WAIT_SECONDS )); then
      rm -f "$capture_marker"
      echo "ERROR: Omi Dev is running build $(plist_get CFBundleVersion), revision ${new_rev:0:10}, but wrote no" >&2
      echo "Rewind captures under $CAPTURE_ROOT in ${CAPTURE_WAIT_SECONDS}s. Screen Recording likely needs" >&2
      echo "re-granting: System Settings > Privacy & Security > Screen & System Audio Recording > Omi Dev" >&2
      echo "(toggle it off and on), then quit and reopen Omi Dev." >&2
      exit 3
    fi
    sleep 15
    waited=$((waited + 15))
  done
  echo "capturing again after ${waited}s"
fi
rm -f "$capture_marker"

echo "Omi Dev redeployed and running: build $(plist_get CFBundleVersion), revision ${new_rev:0:10} (was $old_version)"
echo "done in $((SECONDS / 60))m$((SECONDS % 60))s"
