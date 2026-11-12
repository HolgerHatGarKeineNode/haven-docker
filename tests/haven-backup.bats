#!/usr/bin/env bats
# The host verbs `./haven backup [file]` and `./haven restore <file>` against
# the scripted docker mock (tests/mock/docker, MOCK_DOCKER_STATE_DIR). Each test
# runs a copy of ./haven inside its own sandbox directory, so ROOT_DIR, db/,
# backups/ and .env are the sandbox's, never the checkout's.
# The zips are real (python3 zipfile): one good backup with the five upstream
# entries and a truncated copy of it. Verification uses the host unzip.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup_file() {
  export FIXTURES="$BATS_FILE_TMPDIR/fixtures"
  mkdir -p "$FIXTURES"
  python3 -I - "$FIXTURES" <<'PY'
import sys, zipfile
d = sys.argv[1]
with zipfile.ZipFile(d + "/good.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for n in ("private", "chat", "outbox", "inbox", "blossom"):
        z.writestr(n + ".jsonl", ("{\"id\":\"%s\"}\n" % n) * 400)
data = open(d + "/good.zip", "rb").read()
open(d + "/trunc.zip", "wb").write(data[: len(data) * 2 // 3])
PY
}

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sandbox"
  mkdir -p "$SB/db" "$SB/blossom" "$SB/backups" "$TEST_DIR/bin"
  cp "$REPO_ROOT/haven" "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/docker-compose.tor.yml" "$SB/"
  printf '*\n!.gitignore\n' > "$SB/db/.gitignore"
  local f
  for f in relays_import relays_blastr blacklisted_npubs whitelisted_npubs; do
    printf '[]\n' > "$SB/$f.json"
    printf '[]\n' > "$SB/$f.example.json"
  done
  printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" > "$SB/.env"

  # pinned clock for the default file name
  cat > "$TEST_DIR/bin/date" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%Y%m%d-%H%M%S" ]]; then echo "20260102-030405"; exit 0; fi
exec /usr/bin/env -u PATH /bin/date "$@"
SH
  chmod +x "$TEST_DIR/bin/date"

  PATH="$TEST_DIR/bin:$REPO_ROOT/tests/mock:$PATH"
  export MOCK_DOCKER_STATE_DIR="$TEST_DIR/state"
  mkdir -p "$MOCK_DOCKER_STATE_DIR"
  unset MOCK_STOP_FAILS MOCK_RUN_EXIT MOCK_FAIL_AT MOCK_RUN_WRITES MOCK_RUN_HOLD \
    MOCK_HOLD_MAX MOCK_RUN_PAYLOAD MOCK_RUN_PAYLOAD_FILE HAVEN_HOST_UNZIP
  export HAVEN_CONTAINER_NAME=havenbk-relay
}

teardown() {
  [[ -n "${SB:-}" && -d "$SB/backups" ]] && chmod u+rwx "$SB/backups" 2>/dev/null
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

relay_running() { printf 'havenbk-relay\n' > "$MOCK_DOCKER_STATE_DIR/running"; }
hv() { "$SB/haven" "$@" </dev/null; }
calls() { cat "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null; }
# first line number in calls.log matching an extended regex (empty: none)
line_of() { grep -n -m1 -E -- "$1" "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null | cut -d: -f1; }
# every call that changes docker state
state_changes() { grep -E '^compose .* (stop|start|up|down|run|restart|rm)( |$)' "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null; }
good_payload() { export MOCK_RUN_WRITES=1 MOCK_RUN_PAYLOAD_FILE="$FIXTURES/good.zip"; }

# 1
@test "backup, relay running: stop < run backup /app/backups/<f> < start, verified zip in place" {
  relay_running
  good_payload
  run hv backup nightly.zip
  [ "$status" -eq 0 ]
  local s r t
  s="$(line_of 'docker-compose\.yml stop relay$')"
  r="$(line_of 'docker-compose\.yml run --rm --no-deps -T --name havenbk-relay-oneshot -v [^ ]*/backups:/app/backups --entrypoint /app/haven relay backup /app/backups/nightly\.zip\.partial$')"
  t="$(line_of 'docker-compose\.yml start relay$')"
  [ -n "$s" ] && [ -n "$r" ] && [ -n "$t" ]
  (( s < r && r < t ))
  cmp "$FIXTURES/good.zip" "$SB/backups/nightly.zip"
  [ ! -e "$SB/backups/nightly.zip.partial" ]
  [[ "$output" == *"Backup written: $SB/backups/nightly.zip ($(stat -c %s "$FIXTURES/good.zip") bytes, five entries verified with host unzip)."* ]]
  [[ "$output" == *"does not contain the media files in blossom/, your .env or the JSON lists"* ]]
}

# 2
@test "backup, relay stopped: no stop, no start" {
  good_payload
  run hv backup
  [ "$status" -eq 0 ]
  [ -n "$(line_of ' run .* relay backup /app/backups/')" ]
  [ -z "$(line_of ' stop ')" ]
  [ -z "$(line_of ' (start|up) ')" ]
}

# 3
@test "backup, relay does not stop: rc!=0, hint names ./haven stop, no run" {
  relay_running
  good_payload
  export MOCK_STOP_FAILS=1
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"./haven stop"* ]]
  [ -z "$(line_of ' run ')" ]
  [ ! -e "$SB/backups/x.zip" ]
}

# 4
@test "backup, one-shot fails: rc!=0, relay restarted, no success message, no zip" {
  relay_running
  export MOCK_RUN_EXIT=3
  run hv backup x.zip
  [ "$status" -ne 0 ]
  local r t
  r="$(line_of ' run .* relay backup ')"
  t="$(line_of ' start relay$')"
  [ -n "$r" ] && [ -n "$t" ] && (( r < t ))
  [[ "$output" == *"exited with status 3"* ]]
  [[ "$output" != *"Backup written"* ]]
  [ ! -e "$SB/backups/x.zip" ]
}

# 5
@test "backup, one-shot exits 0 but writes nothing: rc!=0" {
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"reported success but wrote no file"* ]]
  [[ "$output" != *"Backup written"* ]]
  [ ! -e "$SB/backups/x.zip" ]
}

# 6
@test "backup, one-shot exits 0 with a truncated zip: rc!=0, no .zip, .partial kept and named" {
  relay_running
  export MOCK_RUN_WRITES=1 MOCK_RUN_PAYLOAD_FILE="$FIXTURES/trunc.zip"
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [ ! -e "$SB/backups/x.zip" ]
  cmp "$FIXTURES/trunc.zip" "$SB/backups/x.zip.partial"
  [[ "$output" == *"is damaged"* ]]
  [[ "$output" == *"kept for inspection: $SB/backups/x.zip.partial"* ]]
  [[ "$output" != *"Backup written"* ]]
  # the relay still comes back
  [ -n "$(line_of ' start relay$')" ]
}

# 7
@test "backup names: pinned default, path escapes and wrong suffix refused before any docker change, no overwrite" {
  good_payload
  run hv backup
  [ "$status" -eq 0 ]
  [ -f "$SB/backups/haven-backup-20260102-030405.zip" ]
  [ -n "$(line_of ' relay backup /app/backups/haven-backup-20260102-030405\.zip\.partial$')" ]

  local bad
  for bad in ../x.zip /abs/x.zip x.txt; do
    : > "$MOCK_DOCKER_STATE_DIR/calls.log"
    relay_running
    run hv backup "$bad"
    [ "$status" -ne 0 ]
    [ -z "$(state_changes)" ]
  done
  [ ! -e "$TEST_DIR/x.zip" ]

  : > "$MOCK_DOCKER_STATE_DIR/calls.log"
  printf 'old' > "$SB/backups/keep.zip"
  run hv backup keep.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$SB/backups/keep.zip")" = "old" ]
  [ -z "$(state_changes)" ]
}

# 8
@test "backup, unwritable backups/: refused before any stop" {
  [ "$(id -u)" -ne 0 ] || skip "root can write into any directory"
  relay_running
  good_payload
  chmod 555 "$SB/backups"
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"backups/ is not writable for uid $(id -u)"* ]]
  [ -z "$(state_changes)" ]
}

# 9
@test "restore, file missing: no stop, rc!=0, available backups listed; no argument lists them too" {
  relay_running
  cp "$FIXTURES/good.zip" "$SB/backups/there.zip"
  run hv restore missing.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"backups/missing.zip not found"* ]]
  [[ "$output" == *"  there.zip"* ]]
  [ -z "$(state_changes)" ]
  run hv restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"  there.zip"* ]]
  [ -z "$(state_changes)" ]
}

# 10
@test "restore, damaged zip: refused before any stop" {
  relay_running
  cp "$FIXTURES/trunc.zip" "$SB/backups/bad.zip"
  run hv restore bad.zip --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"is damaged"* ]]
  [[ "$output" == *"Nothing was restored"* ]]
  [ -z "$(state_changes)" ]
}

# 11
@test "restore into a non-empty db/: no tty and no --yes refuses without docker change; --yes runs stop < restore < start" {
  relay_running
  mkdir -p "$SB/db/private"
  printf 'x' > "$SB/db/private/MANIFEST"
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  run hv restore good.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"never deletes or duplicates"* ]]
  [[ "$output" == *"--yes"* ]]
  [ -z "$(state_changes)" ]

  run hv restore good.zip --yes
  [ "$status" -eq 0 ]
  local s r t
  s="$(line_of ' stop relay$')"
  r="$(line_of ' run --rm --no-deps -T --name havenbk-relay-oneshot -v [^ ]*/backups:/app/backups --entrypoint /app/haven relay restore /app/backups/good\.zip$')"
  t="$(line_of ' start relay$')"
  [ -n "$s" ] && [ -n "$r" ] && [ -n "$t" ]
  (( s < r && r < t ))
  [[ "$output" == *"Restore finished"* ]]
}

# 12
@test "restore, one-shot fails: rc!=0, relay restarted, message names a possibly partial database" {
  relay_running
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  export MOCK_RUN_EXIT=2
  run hv restore good.zip --yes
  [ "$status" -ne 0 ]
  local r t
  r="$(line_of ' run .* relay restore ')"
  t="$(line_of ' start relay$')"
  [ -n "$r" ] && [ -n "$t" ] && (( r < t ))
  [[ "$output" == *"may now be partially restored"* ]]
  [[ "$output" == *"Running the same restore again is safe"* ]]
  [[ "$output" != *"Restore finished"* ]]
}

# 13
@test "--tor: the tor compose file is used and only relay is stopped" {
  relay_running
  good_payload
  run hv --tor backup t.zip
  [ "$status" -eq 0 ]
  local stops
  stops="$(grep -E '^compose .* (stop|down)( |$)' "$MOCK_DOCKER_STATE_DIR/calls.log")"
  [ "$stops" = "compose -f $SB/docker-compose.tor.yml stop relay" ]
  [ -n "$(line_of "^compose -f $SB/docker-compose\.tor\.yml run .* relay backup /app/backups/t\.zip\.partial$")" ]
  [ -n "$(line_of "^compose -f $SB/docker-compose\.tor\.yml start relay$")" ]
  [ -z "$(grep -F 'docker-compose.yml' "$MOCK_DOCKER_STATE_DIR/calls.log")" ]
}

# 14
@test "help lists backup and restore" {
  run hv help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  backup [file] '* ]]
  [[ "$output" == *$'\n  restore <file> '* ]]
}

# ---------- beyond the list ----------

@test "a leftover one-shot container is named and nothing is stopped" {
  relay_running
  good_payload
  printf 'havenbk-relay-oneshot\n' > "$MOCK_DOCKER_STATE_DIR/exited"
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"still exists: havenbk-relay-oneshot"* ]]
  [ -z "$(state_changes)" ]
}

@test "no host unzip and the image check does not run: fail closed, no backup reported" {
  good_payload
  export HAVEN_HOST_UNZIP=no-such-unzip-4711 MOCK_FAIL_AT=2
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [ -n "$(line_of ' run .* --entrypoint sh relay -c ')" ]
  [[ "$output" == *"could not be verified"* ]]
  [[ "$output" != *"Backup written"* ]]
  [ ! -e "$SB/backups/x.zip" ]
  [ -f "$SB/backups/x.zip.partial" ]
}
