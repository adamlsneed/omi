#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_RESOURCE="${OMI_NODE_RESOURCE_PATH:-$DESKTOP_DIR/Desktop/Sources/Resources/node}"
HOST_ARCH="$(uname -m)"

log() {
  echo "$*"
}

node_has_host_arch() {
  local binary="$1"
  local description
  description="$(file "$binary" 2>/dev/null || true)"

  case "$HOST_ARCH" in
    arm64)
      [[ "$description" == *"arm64"* ]] || [[ "$description" == *"universal binary"* ]] || [[ "$description" == *"script text"* ]]
      ;;
    x86_64)
      [[ "$description" == *"x86_64"* ]] || [[ "$description" == *"universal binary"* ]] || [[ "$description" == *"script text"* ]]
      ;;
    *)
      true
      ;;
  esac
}

node_is_runnable() {
  local binary="$1"
  [ -x "$binary" ] || return 1
  node_has_host_arch "$binary" || return 1
  "$binary" --version >/dev/null 2>&1
}

node_from_command() {
  command -v node >/dev/null 2>&1 || return 1

  local resolved
  resolved="$(node -p 'process.execPath' 2>/dev/null || true)"
  if [ -n "$resolved" ] && node_is_runnable "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  resolved="$(command -v node)"
  if [ -n "$resolved" ] && node_is_runnable "$resolved"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

resolve_node_source() {
  if [ -n "${OMI_NODE_SOURCE:-}" ]; then
    if node_is_runnable "$OMI_NODE_SOURCE"; then
      printf '%s\n' "$OMI_NODE_SOURCE"
      return 0
    fi
    echo "ERROR: OMI_NODE_SOURCE is not an executable Node.js binary: $OMI_NODE_SOURCE" >&2
    return 1
  fi

  if node_from_command; then
    return 0
  fi

  local candidates=(
    "$HOME/.hermes/node/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "/usr/bin/node"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if node_is_runnable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "ERROR: Node.js is required to package desktop AI components." >&2
  echo "Install Node.js, or set OMI_NODE_SOURCE to a runnable node binary." >&2
  return 1
}

if [ "${OMI_SKIP_NODE_RESOURCE:-0}" = "1" ]; then
  log "Skipping bundled Node.js resource (OMI_SKIP_NODE_RESOURCE=1)"
  exit 0
fi

if node_is_runnable "$NODE_RESOURCE"; then
  log "Bundled Node.js resource already prepared: $NODE_RESOURCE"
  exit 0
fi

SOURCE_NODE="$(resolve_node_source)"
mkdir -p "$(dirname "$NODE_RESOURCE")"

tmp_node="$NODE_RESOURCE.tmp.$$"
cp -f "$SOURCE_NODE" "$tmp_node"
chmod +x "$tmp_node"
xattr -cr "$tmp_node" 2>/dev/null || true

if [ "${OMI_NODE_ADHOC_SIGN:-1}" = "1" ] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$tmp_node" >/dev/null 2>&1 || true
fi

mv -f "$tmp_node" "$NODE_RESOURCE"

if ! node_is_runnable "$NODE_RESOURCE"; then
  echo "ERROR: Prepared Node.js resource is not runnable: $NODE_RESOURCE" >&2
  exit 1
fi

log "Prepared bundled Node.js resource from $SOURCE_NODE"
