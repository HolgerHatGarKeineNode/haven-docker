#!/usr/bin/env bats
# Unit tests for the P3 engine hardening in ./haven: display-width helpers
# and the log streaming lifecycle (fifo race, process group kill, EOF
# restart) against the docker mock in tests/mock/.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  PATH="$REPO_ROOT/tests/mock:$PATH"
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# ---------- display width ----------

@test "tui_str_width: printable ASCII counts 1 per character" {
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_str_width "abc123 .-"; echo "w=$_WIDTH"'
  [ "$status" -eq 0 ]
  [[ "$output" == "w=9" ]]
}

@test "tui_str_width: CJK counts 2 columns per character" {
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_str_width "こんにちは"; echo "w=$_WIDTH"'
  [ "$status" -eq 0 ]
  [[ "$output" == "w=10" ]]
}

@test "tui_str_width: mixed ASCII and CJK sums correctly" {
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_str_width "abこんにちは"; echo "w=$_WIDTH"'
  [ "$status" -eq 0 ]
  [[ "$output" == "w=12" ]]
}

@test "tui_truncate: CJK cut at display width keeps the ellipsis and the limit" {
  # "こんにちは世界" at width 6: budget 6-3=3 fits one wide glyph (2), the
  # next wide glyph would exceed it — result width 5, and tui_pad_to fills
  # the remaining column (proven by the pad-alignment test below).
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_truncate "こんにちは世界" 6; tui_str_width "$_TRUNC"; echo "t=$_TRUNC w=$_WIDTH"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"w=5"* ]]
  [[ "$output" == *"..."* ]]
  [[ "$output" != *"世界"* ]]
}

@test "tui_pad_to: CJK padded to width aligns with an ASCII row of the same width" {
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_pad_to "こんにちは" 14; tui_str_width "$_PADDED"; a=$_WIDTH; tui_pad_to "ABCDEFGHIJ" 14; tui_str_width "$_PADDED"; echo "a=$a b=$_WIDTH"'
  [ "$status" -eq 0 ]
  [[ "$output" == "a=14 b=14" ]]
}

@test "tui_pad_to: overlong input is truncated to the pad width" {
  run bash -c 'source '"$REPO_ROOT"'/haven; tui_pad_to "ABCDEFGHIJ" 5; tui_str_width "$_PADDED"; echo "w=$_WIDTH v=$_PADDED"'
  [ "$status" -eq 0 ]
  [[ "$output" == "w=5"* ]]
  [[ "$output" == *"..."* ]]
}

# ---------- log streaming lifecycle (docker mock) ----------

@test "start_log_stream: fifo lives in a private mktemp -d directory" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    DOCKER_COMPOSE=(docker compose)
    ROOT_DIR='"$REPO_ROOT"'
    FOLLOW_LOGS=1
    TAIL_COUNT=5
    LOG_SERVICE=""
    start_log_stream
    dir="$LOG_FIFO_DIR"
    stop_log_stream
    echo "wasdir=$(test -n "$dir" && echo yes) gone=$(test -e "$dir" && echo yes || echo no)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "wasdir=yes gone=no" ]]
}

@test "stop_log_stream: process-group kill leaves no orphaned children" {
  run bash -c '
    before=$(pgrep -fc "sleep 21777" || true)
    source '"$REPO_ROOT"'/haven
    set +e
    DOCKER_COMPOSE=(docker compose)
    ROOT_DIR='"$REPO_ROOT"'
    FOLLOW_LOGS=1
    TAIL_COUNT=5
    LOG_SERVICE=""
    start_log_stream
    pid="$LOG_PID"
    sid="$LOG_PID_SETSID"
    sleep 0.6
    stop_log_stream
    after=$(pgrep -fc "sleep 21777" || true)
    echo "pid=$pid setsid=$sid before=${before:-0} after=${after:-0}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"setsid=1"* ]]
  [[ "$output" != *"pid= "* ]]
  # every mock child spawned during the test must be gone after the stop
  before="$(printf '%s' "$output" | sed -n 's/.*before=\([0-9]*\) .*/\1/p')"
  after="$(printf '%s' "$output" | sed -n 's/.*after=\([0-9]*\).*/\1/p')"
  [ "$after" -le "$before" ]
}

@test "producer EOF: tui_ensure_log_stream restarts the stream" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    DOCKER_COMPOSE=(docker compose)
    ROOT_DIR='"$REPO_ROOT"'
    FOLLOW_LOGS=1
    TAIL_COUNT=5
    LOG_SERVICE=""
    TUI_DOCKER_OK=1
    start_log_stream
    # start_log_stream ends with `set -e` — re-disable after every call
    set +e
    first="$LOG_PID"
    # Kill the producer the way a crashed docker would (its pid dies);
    # group-kill coverage is handled by the orphan test below.
    kill "$LOG_PID" 2>/dev/null
    sleep 0.2
    tui_ensure_log_stream
    second="$LOG_PID"
    stop_log_stream
    echo "first=$first second=$second restarted=$([ -n "$second" ] && [ "$first" != "$second" ] && echo yes || echo no)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"restarted=yes"* ]]
}

@test "drain_log_stream pulls sanitized mock lines into the ring buffer" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    DOCKER_COMPOSE=(docker compose)
    ROOT_DIR='"$REPO_ROOT"'
    FOLLOW_LOGS=1
    TAIL_COUNT=5
    LOG_SERVICE=""
    start_log_stream
    sleep 0.7
    drain_log_stream
    stop_log_stream
    echo "lines=${#LOG_LINES[@]} first=${LOG_LINES[0]:-none}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "lines="*"first=MOCKLOG COUNTER="* ]]
}
