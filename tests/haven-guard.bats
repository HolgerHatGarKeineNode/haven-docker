#!/usr/bin/env bats
# haven-guard.sh (installed as /app/haven in the image) refuses a second
# haven-bin and tells a user inside the container which host command to run.
# The guard detects "another haven-bin" by scanning /proc; the stand-in here is
# a sleep whose argv[0] is haven-bin (exec -a), started and ended by this test
# by its own pid. Nothing of the image is needed.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
bats_require_minimum_version 1.5.0

setup() {
  bash -c 'exec -a haven-bin sleep 60' &
  STANDIN_PID=$!
  local i
  for ((i = 0; i < 100; i++)); do
    tr -d '\000' < "/proc/$STANDIN_PID/cmdline" 2>/dev/null | grep -q '^haven-bin' && return 0
    sleep 0.02
  done
  return 1
}

teardown() {
  [[ -n "${STANDIN_PID:-}" ]] && kill "$STANDIN_PID" 2>/dev/null
  wait "$STANDIN_PID" 2>/dev/null || true
}

guard() { sh "$REPO_ROOT/haven-guard.sh" "$@"; }

@test "guard: backup names ./haven backup on the host, no dead end" {
  run guard backup /app/backups/x.zip
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"haven is already running in this container (pid "* ]]
  [[ "$output" == *$'\n       ./haven backup\n'* ]]
  [[ "$output" == *"writes a verified zip to backups/"* ]]
  [[ "$output" != *"./haven stop"* ]]
  [[ "$output" != *"against the stopped relay"* ]]
}

@test "guard: restore names ./haven restore <file> on the host, no dead end" {
  run guard restore /app/backups/x.zip
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'\n       ./haven restore <file>\n'* ]]
  [[ "$output" == *"adds the events that are missing"* ]]
  [[ "$output" != *"./haven stop"* ]]
}

@test "guard: import keeps its wording" {
  run guard import
  [ "$status" -eq 1 ]
  [[ "$output" == *$'\n       ./haven import\n'* ]]
  [[ "$output" == *"It stops the relay, imports once in the foreground, and starts the relay again."* ]]
}

@test "guard: any other command keeps today's wording" {
  run guard migrate
  [ "$status" -eq 1 ]
  [[ "$output" == *"'migrate' opens the same database"* ]]
  [[ "$output" == *$'\n       ./haven stop\n'* ]]
}

@test "guard: positive control — without a second haven-bin the guard execs the binary (absent here)" {
  kill "$STANDIN_PID"; wait "$STANDIN_PID" 2>/dev/null || true
  STANDIN_PID=""
  # another haven-bin on this host (a running relay container) makes the
  # control meaningless; skip rather than assert on it
  local p
  for p in /proc/[0-9]*; do
    tr -d '\000' < "$p/cmdline" 2>/dev/null | grep -q 'haven-[b]in' && skip "a haven-bin runs on this host (pid ${p#/proc/}: $(tr "\\000" " " < "$p/cmdline" 2>/dev/null | cut -c1-80))"
  done
  run -127 guard backup
  echo "$output"
  [[ "$output" != *"already running"* ]]
  [[ "$output" == *"/app/haven-bin"* ]]
}
