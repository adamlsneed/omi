#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare-node-resource.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fake_node() {
  local path="$1"
  cat > "$path" <<'NODE'
#!/bin/sh
if [ "$1" = "-p" ]; then
  printf '%s\n' "$0"
else
  printf 'v99.0.0\n'
fi
NODE
  chmod +x "$path"
}

run_in_tmp() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  "$@" "$tmp"
}

test_copies_explicit_node_source() {
  local tmp="$1"
  local source="$tmp/fake-node"
  local resource="$tmp/Desktop/Sources/Resources/node"
  make_fake_node "$source"

  OMI_NODE_SOURCE="$source" \
    OMI_NODE_RESOURCE_PATH="$resource" \
    OMI_NODE_ADHOC_SIGN=0 \
    bash "$PREPARE_SCRIPT" >/dev/null

  [ -x "$resource" ] || fail "expected copied node to be executable"
  [ "$("$resource" --version)" = "v99.0.0" ] || fail "copied node did not execute"
}

test_keeps_existing_runnable_resource() {
  local tmp="$1"
  local existing="$tmp/Desktop/Sources/Resources/node"
  local other="$tmp/other-node"
  mkdir -p "$(dirname "$existing")"
  make_fake_node "$existing"
  make_fake_node "$other"

  OMI_NODE_SOURCE="$other" \
    OMI_NODE_RESOURCE_PATH="$existing" \
    OMI_NODE_ADHOC_SIGN=0 \
    bash "$PREPARE_SCRIPT" >/dev/null

  [ "$("$existing" --version)" = "v99.0.0" ] || fail "existing node was not runnable after prepare"
}

test_discovers_node_from_path() {
  local tmp="$1"
  local bindir="$tmp/bin"
  local resource="$tmp/Desktop/Sources/Resources/node"
  mkdir -p "$bindir"
  make_fake_node "$bindir/node"

  PATH="$bindir:/usr/bin:/bin" \
    OMI_NODE_RESOURCE_PATH="$resource" \
    OMI_NODE_ADHOC_SIGN=0 \
    HOME="$tmp/home" \
    bash "$PREPARE_SCRIPT" >/dev/null

  [ -x "$resource" ] || fail "expected PATH-discovered node to be copied"
  [ "$("$resource" --version)" = "v99.0.0" ] || fail "PATH-discovered node did not execute"
}

test_invalid_explicit_node_source_fails() {
  local tmp="$1"
  local resource="$tmp/Desktop/Sources/Resources/node"

  if OMI_NODE_SOURCE="$tmp/missing-node" \
    OMI_NODE_RESOURCE_PATH="$resource" \
    OMI_NODE_ADHOC_SIGN=0 \
    bash "$PREPARE_SCRIPT" >/dev/null 2>&1; then
    fail "invalid explicit node source should fail"
  fi
}

run_in_tmp test_copies_explicit_node_source
run_in_tmp test_keeps_existing_runnable_resource
run_in_tmp test_discovers_node_from_path
run_in_tmp test_invalid_explicit_node_source_fails

echo "prepare-node-resource tests passed"
