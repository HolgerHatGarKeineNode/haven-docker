#!/usr/bin/env bats
# Tests for the scripted mode of tests/mock/docker (active only when
# MOCK_DOCKER_STATE_DIR is set). Every switch the mock offers has a case that
# turns red when the switch stops working; the unscripted behaviour is pinned
# by one case, the 71 older tests are its main proof.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  PATH="$REPO_ROOT/tests/mock:$PATH"
  TEST_DIR="$(mktemp -d)"
  export MOCK_DOCKER_STATE_DIR="$TEST_DIR/state"
  unset MOCK_STOP_FAILS MOCK_RUN_EXIT MOCK_FAIL_AT MOCK_RUN_WRITES MOCK_RUN_HOLD \
    MOCK_HOLD_MAX MOCK_RUN_PAYLOAD HAVEN_CONTAINER_NAME
  mkdir -p "$MOCK_DOCKER_STATE_DIR"
}

teardown() {
  # a failed assertion must not leave a backgrounded mock holding bats' pipes
  if [[ -n "${BG_PID:-}" ]]; then
    kill "$BG_PID" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
  fi
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

calls() { cat "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null; }

# ---------- unscripted mode stays as it was ----------

@test "unscripted: no state dir, fixed container list, nothing written" {
  unset MOCK_DOCKER_STATE_DIR
  run docker ps --format '{{.Names}}'
  [ "$status" -eq 0 ]
  [[ "$output" == "haven-relay" ]]
  run docker ps -a --format '{{.Names}}'
  [[ "$output" == $'haven-relay\nhaven-tor' ]]
  run docker compose version
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_DIR/state/calls.log" ]
  # an empty variable counts as unset
  MOCK_DOCKER_STATE_DIR="" run docker ps -a --format '{{.Names}}'
  [[ "$output" == $'haven-relay\nhaven-tor' ]]
}

# ---------- compose subcommands: fast, logged, flags skipped ----------

@test "scripted: compose stop|start|run|ps each return within 1 s and are logged in order" {
  local sub
  for sub in stop start run ps; do
    run timeout 1 docker compose -f /x/docker-compose.yml -p proj "$sub" relay
    [ "$status" -eq 0 ]
  done
  run calls
  [[ "$output" == $'compose -f /x/docker-compose.yml -p proj stop relay\ncompose -f /x/docker-compose.yml -p proj start relay\ncompose -f /x/docker-compose.yml -p proj run relay\ncompose -f /x/docker-compose.yml -p proj ps relay' ]]
}

@test "scripted: unknown compose subcommand and non-compose commands are logged and return 0 fast" {
  run timeout 1 docker compose -f f.yml pull
  [ "$status" -eq 0 ]
  run timeout 1 docker volume ls
  [ "$status" -eq 0 ]
  run calls
  [[ "$output" == $'compose -f f.yml pull\nvolume ls' ]]
}

@test "scripted: dispatch is on the subcommand, not on a flag value named like one" {
  # '-f stop' must not be taken for the stop subcommand
  echo haven-relay > "$MOCK_DOCKER_STATE_DIR/running"
  run timeout 1 docker compose -f stop ps
  [ "$status" -eq 0 ]
  run docker ps --format '{{.Names}}'
  [[ "$output" == "haven-relay" ]]
}

# ---------- ps / stop / start ----------

@test "scripted: docker ps and compose ps both read the running file" {
  run docker ps --format '{{.Names}}'
  [ -z "$output" ]
  printf 'haven-relay\nhaven-tor\n' > "$MOCK_DOCKER_STATE_DIR/running"
  run docker ps --format '{{.Names}}'
  [[ "$output" == $'haven-relay\nhaven-tor' ]]
  run docker ps --format '{{.Names}}|{{.Status}}'
  [[ "$output" == $'haven-relay|Up 2 hours (healthy)\nhaven-tor|Up 2 hours (healthy)' ]]
  run docker compose -f f.yml ps
  [[ "$output" == *"haven-relay"* && "$output" == *"haven-tor"* ]]
}

@test "scripted: stop clears running and the container shows as exited in ps -a" {
  echo haven-relay > "$MOCK_DOCKER_STATE_DIR/running"
  run docker compose -f f.yml stop relay
  [ "$status" -eq 0 ]
  run docker ps --format '{{.Names}}'
  [ -z "$output" ]
  run docker ps -a --format '{{.Names}}|{{.Status}}'
  [[ "$output" == "haven-relay|Exited (0) 4 minutes ago" ]]
}

@test "scripted: MOCK_STOP_FAILS=1 leaves the relay running although stop returns 0" {
  echo haven-relay > "$MOCK_DOCKER_STATE_DIR/running"
  MOCK_STOP_FAILS=1 run docker compose -f f.yml stop relay
  [ "$status" -eq 0 ]
  run docker ps --format '{{.Names}}'
  [[ "$output" == "haven-relay" ]]
  run calls
  [[ "$output" == *"stop relay"* ]]
}

@test "scripted: start and up mark the container running, under HAVEN_CONTAINER_NAME when set" {
  run docker compose -f f.yml start relay
  run docker ps --format '{{.Names}}'
  [[ "$output" == "haven-relay" ]]
  run docker compose -f f.yml stop relay
  run docker ps --format '{{.Names}}'
  [ -z "$output" ]
  HAVEN_CONTAINER_NAME=haven-test-4711 run docker compose -f f.yml up -d
  run docker ps --format '{{.Names}}'
  [[ "$output" == "haven-test-4711" ]]
}

@test "scripted: down clears running" {
  echo haven-relay > "$MOCK_DOCKER_STATE_DIR/running"
  run docker compose -f f.yml down --remove-orphans
  [ "$status" -eq 0 ]
  run docker ps --format '{{.Names}}'
  [ -z "$output" ]
}

# ---------- run: exit code, failure at the n-th call ----------

@test "scripted: run exits 0 by default and counts its calls" {
  run docker compose -f f.yml run --rm relay
  [ "$status" -eq 0 ]
  run docker compose -f f.yml run --rm relay
  [ "$(cat "$MOCK_DOCKER_STATE_DIR/run-count")" = "2" ]
}

@test "scripted: MOCK_RUN_EXIT sets the exit status of every run" {
  MOCK_RUN_EXIT=7 run docker compose -f f.yml run --rm relay
  [ "$status" -eq 7 ]
  MOCK_RUN_EXIT=7 run docker compose -f f.yml run --rm relay
  [ "$status" -eq 7 ]
}

@test "scripted: MOCK_FAIL_AT=2 fails the second run only, with 1 or with MOCK_RUN_EXIT" {
  export MOCK_FAIL_AT=2
  run docker compose -f f.yml run --rm relay
  [ "$status" -eq 0 ]
  run docker compose -f f.yml run --rm relay
  [ "$status" -eq 1 ]
  run docker compose -f f.yml run --rm relay
  [ "$status" -eq 0 ]
  # a fresh state dir restarts the count; MOCK_RUN_EXIT picks the code
  rm -f "$MOCK_DOCKER_STATE_DIR/run-count"
  export MOCK_RUN_EXIT=9
  unset MOCK_FAIL_AT
  MOCK_FAIL_AT=1 run docker compose -f f.yml run --rm relay
  [ "$status" -eq 9 ]
}

@test "scripted: MOCK_FAIL_AT does not count other compose subcommands" {
  export MOCK_FAIL_AT=1
  run docker compose -f f.yml stop relay
  run docker compose -f f.yml start relay
  [ "$status" -eq 0 ]
  run docker compose -f f.yml run --rm relay
  [ "$status" -eq 1 ]
}

# ---------- run: MOCK_RUN_WRITES ----------

@test "scripted: backup run exits 0 and writes no file without MOCK_RUN_WRITES" {
  mkdir -p "$TEST_DIR/backups"
  run docker compose -f f.yml run --rm --no-deps -v "$TEST_DIR/backups:/app/backups" --entrypoint /app/haven relay backup /app/backups/a.zip
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TEST_DIR/backups")" ]
}

@test "scripted: MOCK_RUN_WRITES=1 creates the backup file on the host side of the mount" {
  mkdir -p "$TEST_DIR/backups"
  MOCK_RUN_WRITES=1 run docker compose -f f.yml run --rm --no-deps -v "$TEST_DIR/backups:/app/backups" --entrypoint /app/haven relay backup /app/backups/a.zip
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/backups/a.zip")" = "mock-backup" ]
  MOCK_RUN_PAYLOAD=custom MOCK_RUN_WRITES=1 run docker compose -f f.yml run --rm -v "$TEST_DIR/backups:/app/backups" --entrypoint /app/haven relay backup /app/backups/b.zip
  [ "$(cat "$TEST_DIR/backups/b.zip")" = "custom" ]
}

@test "scripted: MOCK_RUN_WRITES=1 writes nothing for restore, without a mount, or outside /app/backups" {
  mkdir -p "$TEST_DIR/backups"
  MOCK_RUN_WRITES=1 run docker compose -f f.yml run --rm -v "$TEST_DIR/backups:/app/backups" --entrypoint /app/haven relay restore /app/backups/a.zip
  [ "$status" -eq 0 ]
  MOCK_RUN_WRITES=1 run docker compose -f f.yml run --rm --entrypoint /app/haven relay backup /app/backups/a.zip
  [ "$status" -eq 0 ]
  MOCK_RUN_WRITES=1 run docker compose -f f.yml run --rm -v "$TEST_DIR/backups:/app/backups" --entrypoint /app/haven relay backup /tmp/escape.zip
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TEST_DIR/backups")" ]
}

# ---------- run: hold gate ----------

@test "scripted: MOCK_RUN_HOLD=1 holds run until release appears, and release ends it well inside the bound" {
  # The bound is set far above what a working release needs. A mock that
  # ignored the release file would still exit 0 — but only after sitting out
  # the whole bound, which the elapsed-time check below tells apart.
  export MOCK_HOLD_MAX=20
  local t0 t1
  t0="$(date +%s%N)"
  MOCK_RUN_HOLD=1 docker compose -f f.yml run --rm relay &
  local pid=$! i
  for i in $(seq 1 100); do
    [[ -e "$MOCK_DOCKER_STATE_DIR/started" ]] && break
    sleep 0.05
  done
  [ -e "$MOCK_DOCKER_STATE_DIR/started" ]
  # held: still alive with the gate open
  kill -0 "$pid"
  touch "$MOCK_DOCKER_STATE_DIR/release"
  local rc=0
  wait "$pid" || rc=$?
  t1="$(date +%s%N)"
  [ "$rc" -eq 0 ]
  # released: gone within half of the 20 s bound (a working release takes
  # ~0.1 s; a mock that waits out the bound takes 20 s)
  [ $(( (t1 - t0) / 1000000 )) -lt 10000 ]
}

@test "scripted: the hold gate is bounded by MOCK_HOLD_MAX" {
  local t0 t1
  t0="$(date +%s%N)"
  MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=0.3 run docker compose -f f.yml run --rm relay
  t1="$(date +%s%N)"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_DOCKER_STATE_DIR/release" ]
  # waited roughly the bound, and certainly not the default 10 s
  [ $(( (t1 - t0) / 1000000 )) -ge 250 ]
  [ $(( (t1 - t0) / 1000000 )) -lt 3000 ]
}

@test "scripted: a held run dies on SIGTERM instead of waiting out the bound" {
  MOCK_RUN_HOLD=1 docker compose -f f.yml run --rm relay &
  local pid=$! i
  for i in $(seq 1 100); do
    [[ -e "$MOCK_DOCKER_STATE_DIR/started" ]] && break
    sleep 0.05
  done
  # (SIGINT would be ignored here: bash starts `&` jobs of a non-interactive
  # shell with SIGINT disabled — signal tests of the verbs must not rely on it)
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  # 143 = killed by SIGTERM; a held run that ignored it would exit 0 after the bound
  [ "$rc" -eq 143 ]
  [ ! -e "$MOCK_DOCKER_STATE_DIR/release" ]
}

# ---------- logs keep the counter stream ----------

@test "scripted: compose logs is logged and still streams the counter, no orphan left" {
  local before after
  before="$(pgrep -fc 'sleep 21777' || true)"
  run timeout 1 docker compose -f f.yml logs -f relay
  [ "$status" -eq 124 ]
  [[ "$output" == *"MOCKLOG COUNTER=0"* ]]
  run calls
  [[ "$output" == "compose -f f.yml logs -f relay" ]]
  after="$(pgrep -fc 'sleep 21777' || true)"
  [ "${after:-0}" -le "${before:-0}" ]
}

# ---------- MOCK_LOG_COUNT: a frozen stream ----------

# bg_mock <outfile> — the mock's `compose logs -f` in the background, output in
# <outfile>, its pid in BG_PID (teardown ends it; fd 3 closed so bats cannot
# hang on it). `timeout` is only the safety bound.
bg_mock() {
  timeout 60 docker compose -f f.yml logs -f relay > "$1" 2>/dev/null 3>&- &
  BG_PID=$!
}

# wait_lines <file> <n> — true once the file holds at least n lines (bounded: 10 s)
wait_lines() {
  local i
  for ((i = 0; i < 200; i++)); do
    (( $(wc -l < "$1") >= $2 )) && return 0
    sleep 0.05
  done
  return 1
}

# reap — end the backgrounded mock now (TERM: `&` jobs of a non-interactive shell
# ignore INT)
reap() {
  kill "$BG_PID" 2>/dev/null || true
  wait "$BG_PID" 2>/dev/null || true
  BG_PID=""
}

@test "scripted: MOCK_LOG_COUNT=7 emits exactly COUNTER=0..6, then stays attached without emitting" {
  local out="$TEST_DIR/out" before after
  before="$(pgrep -fc 'sleep 21777' || true)"
  MOCK_LOG_COUNT=7 bg_mock "$out"
  wait_lines "$out" 7
  # observation window: five ticks of the endless stream's 200 ms rhythm; a mock
  # that goes on counting would have written COUNTER=7 long before it ends
  sleep 1
  kill -0 "$BG_PID"   # still attached: a finished producer would trip the TUI's restart
  [[ "$(cat "$out")" == $'MOCKLOG COUNTER=0\nMOCKLOG COUNTER=1\nMOCKLOG COUNTER=2\nMOCKLOG COUNTER=3\nMOCKLOG COUNTER=4\nMOCKLOG COUNTER=5\nMOCKLOG COUNTER=6' ]]
  reap
  after="$(pgrep -fc 'sleep 21777' || true)"
  [ "${after:-0}" -le "${before:-0}" ]
}

@test "scripted: MOCK_LOG_COUNT unset or empty keeps the endless stream (control for the frozen one)" {
  local out="$TEST_DIR/out"
  MOCK_LOG_COUNT="" bg_mock "$out"
  wait_lines "$out" 9   # more lines than the frozen cases above ever produce
  reap
  [[ "$(sed -n 9p "$out")" == "MOCKLOG COUNTER=8" ]]
}

@test "scripted: MOCK_LOG_COUNT=0 emits nothing and stays attached" {
  local out="$TEST_DIR/out"
  MOCK_LOG_COUNT=0 bg_mock "$out"
  sleep 1
  kill -0 "$BG_PID"
  [ ! -s "$out" ]
  reap
}

@test "scripted: a non-numeric MOCK_LOG_COUNT is refused with exit 2, not read as an empty stream" {
  local before after
  before="$(pgrep -fc 'sleep 21777' || true)"
  MOCK_LOG_COUNT=abc run timeout 5 docker compose -f f.yml logs -f relay
  [ "$status" -eq 2 ]
  [[ "$output" == *"MOCK_LOG_COUNT must be a non-negative integer"* ]]
  after="$(pgrep -fc 'sleep 21777' || true)"
  [ "${after:-0}" -le "${before:-0}" ]
}
