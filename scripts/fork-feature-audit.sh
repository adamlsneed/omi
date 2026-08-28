#!/usr/bin/env bash
# LIFECYCLE: permanent
#
# Fork-feature audit (adamlsneed/omi). Run after every upstream sync: each
# fork-only feature must still resolve to at least one live source file, so a
# merge that silently dropped one fails loudly here instead of shipping.
# The inventory mirrors the fork-features memory note; keep the two in step.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

failures=0

check() {
  local symbol="$1" dir="$2" label="$3"
  local count
  count=$(grep -rl "$symbol" "$dir" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    echo "MISSING: $label ($symbol in $dir)"
    failures=$((failures + 1))
  else
    echo "ok: $label ($count files)"
  fi
}

check ideaFolderId app/lib "app idea capture filing"
check FrontendTemplateRouter app/lib "app template routing"
check appleRemindersAutoExport app/lib "app Apple Reminders auto-export"
check _isManagedByNative app/lib "app BLE re-discover/reconnect"
check IdeaCapture desktop/macos/Desktop/Sources "desktop idea capture"
check TaskPromotionService desktop/macos/Desktop/Sources "desktop task auto-promote"
check DockIconVisibility desktop/macos/Desktop/Sources "desktop Dock icon toggle"
check AudioChannel desktop/macos/Desktop/Sources "desktop multi-channel transcription"
check CaptureTrigger desktop/macos/Desktop/Sources "desktop capture provenance"
check makeAgentSubprocessEnvironment desktop/macos/Desktop/Sources "agent subprocess env hardening"
check idea_capture_active omi/firmware/omi/src "firmware idea capture"

haiku=$(grep -c 'claude-haiku-4-5' desktop/macos/Desktop/Sources/ModelQoS.swift || true)
if [ "$haiku" -eq 0 ]; then
  echo "MISSING: ModelQoS Haiku defaults (claude-haiku-4-5 in ModelQoS.swift)"
  failures=$((failures + 1))
else
  echo "ok: ModelQoS Haiku defaults ($haiku refs)"
fi

# Upstream's omi.conf once carried a stale lower version; taking it would
# advertise a downgrade below the flashed pendant firmware.
fw=$(grep -o 'CONFIG_BT_DIS_FW_REV_STR="[0-9.]*"' omi/firmware/omi/omi.conf | grep -o '[0-9.]*')
min_fw="3.0.25"
if [ "$(printf '%s\n' "$min_fw" "$fw" | sort -V | head -1)" != "$min_fw" ]; then
  echo "REGRESSED: firmware version $fw is below $min_fw in omi/firmware/omi/omi.conf"
  failures=$((failures + 1))
else
  echo "ok: firmware version $fw (>= $min_fw)"
fi

if [ "$failures" -gt 0 ]; then
  echo "fork-feature-audit: $failures check(s) FAILED"
  exit 1
fi
echo "fork-feature-audit: all checks passed"
