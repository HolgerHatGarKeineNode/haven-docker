#!/usr/bin/env bats
# The two test seams in ./haven: HAVEN_CONTAINER_NAME (relay container name on
# the host side) and HAVEN_TUI_SYNC_FILE (render counter). Both must be inert
# when unset — the older suites are the proof for the TUI itself; here the
# seams are pinned in both directions.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  PATH="$REPO_ROOT/tests/mock:$PATH"
  TEST_DIR="$(mktemp -d)"
  export MOCK_DOCKER_STATE_DIR="$TEST_DIR/state"
  mkdir -p "$MOCK_DOCKER_STATE_DIR"
  unset HAVEN_CONTAINER_NAME HAVEN_TUI_SYNC_FILE
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# relay_probe <running-file-content> — prints yes/no for relay_container_running
relay_probe() {
  printf '%s' "$1" > "$MOCK_DOCKER_STATE_DIR/running"
  bash -c 'source '"$REPO_ROOT"'/haven; set +e; relay_container_running && echo yes || echo no'
}

# ---------- HAVEN_CONTAINER_NAME ----------

@test "seam name: unset keeps haven-relay as the relay container" {
  run relay_probe $'haven-relay\n'
  [[ "$output" == "yes" ]]
  run relay_probe $'other\n'
  [[ "$output" == "no" ]]
}

@test "seam name: an exact match is required (haven-relay-2 is not haven-relay)" {
  run relay_probe $'haven-relay-2\n'
  [[ "$output" == "no" ]]
}

@test "seam name: HAVEN_CONTAINER_NAME selects another container and stops matching haven-relay" {
  export HAVEN_CONTAINER_NAME=haven-test-4711
  run relay_probe $'haven-test-4711\n'
  [[ "$output" == "yes" ]]
  # the real relay running next to the test one must not count
  run relay_probe $'haven-relay\n'
  [[ "$output" == "no" ]]
}

@test "seam name: an empty HAVEN_CONTAINER_NAME falls back to haven-relay" {
  export HAVEN_CONTAINER_NAME=""
  run relay_probe $'haven-relay\n'
  [[ "$output" == "yes" ]]
}

@test "seam name: the digest lookup asks docker about the configured name" {
  export HAVEN_CONTAINER_NAME=haven-test-4711
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e; tui_collect_status; printf "%s\n" "${TUI_STATUS_CACHE[@]}"'
  [ "$status" -eq 0 ]
  grep -qxF "inspect --format {{.Image}} haven-test-4711" "$MOCK_DOCKER_STATE_DIR/calls.log"
  ! grep -q "inspect --format {{.Image}} haven-relay" "$MOCK_DOCKER_STATE_DIR/calls.log"
}

@test "seam name: unset, the digest lookup still asks for haven-relay" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e; tui_collect_status'
  [ "$status" -eq 0 ]
  grep -qxF "inspect --format {{.Image}} haven-relay" "$MOCK_DOCKER_STATE_DIR/calls.log"
}

@test "seam name: the status list shows a configured name that lacks the haven- prefix" {
  export HAVEN_CONTAINER_NAME=relay-under-test
  printf 'relay-under-test\nunrelated\n' > "$MOCK_DOCKER_STATE_DIR/running"
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e; tui_collect_status; printf "%s\n" "${TUI_STATUS_CACHE[@]}"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay-under-test: running"* ]]
  [[ "$output" != *"unrelated"* ]]
}

@test "seam name: restart_after_env_change finds the relay by the configured name" {
  export HAVEN_CONTAINER_NAME=haven-test-4711
  printf 'haven-test-4711\n' > "$MOCK_DOCKER_STATE_DIR/running"
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e; restart_services() { echo "restart:$1"; }; restart_after_env_change'
  [[ "$output" == *"restart:plain"* ]]
  # and not when only the default-named relay runs
  printf 'haven-relay\n' > "$MOCK_DOCKER_STATE_DIR/running"
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e; restart_services() { echo "restart:$1"; }; restart_after_env_change'
  [[ "$output" == *"No running containers to restart"* ]]
  [[ "$output" != *"restart:"* ]]
}

# ---------- HAVEN_TUI_SYNC_FILE ----------

@test "seam sync: unset writes nothing, not even a temp file" {
  run bash -c 'source '"$REPO_ROOT"'/haven; cd '"$TEST_DIR"'; tui_sync_mark; tui_sync_mark; echo count=$TUI_SYNC_COUNT'
  [ "$status" -eq 0 ]
  [[ "$output" == "count=0" ]]
  [ -z "$(ls -A "$TEST_DIR" | grep -v '^state$')" ]
}

@test "seam sync: set, the number increments by one per mark and leaves no temp file" {
  export HAVEN_TUI_SYNC_FILE="$TEST_DIR/sync"
  run bash -c 'source '"$REPO_ROOT"'/haven
    tui_sync_mark; a=$(cat "$HAVEN_TUI_SYNC_FILE")
    tui_sync_mark; b=$(cat "$HAVEN_TUI_SYNC_FILE")
    tui_sync_mark; c=$(cat "$HAVEN_TUI_SYNC_FILE")
    echo "$a $b $c"'
  [ "$status" -eq 0 ]
  [[ "$output" == "1 2 3" ]]
  [ ! -e "$TEST_DIR/sync.tmp" ]
}

@test "seam sync: an unwritable target does not abort the caller (set -e)" {
  export HAVEN_TUI_SYNC_FILE="$TEST_DIR/no/such/dir/sync"
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_sync_mark; echo survived'
  [ "$status" -eq 0 ]
  [[ "$output" == "survived" ]]
}
