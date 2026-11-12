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
  mkdir -p "$SB/db" "$SB/blossom" "$TEST_DIR/bin"
  # backup and restore refuse a backups/ that others can write; pin the mode so
  # the suite does not depend on the caller's umask
  mkdir -m 700 "$SB/backups"
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
    MOCK_HOLD_MAX MOCK_RUN_PAYLOAD MOCK_RUN_PAYLOAD_FILE HAVEN_HOST_UNZIP \
    MOCK_START_FAILS MOCK_STOP_SLEEP
  export HAVEN_CONTAINER_NAME=havenbk-relay
}

teardown() {
  # a held mock `run` left behind by a failed signal test ends at once
  [[ -n "${MOCK_DOCKER_STATE_DIR:-}" && -d "$MOCK_DOCKER_STATE_DIR" ]] && : > "$MOCK_DOCKER_STATE_DIR/release"
  [[ -n "${SB:-}" && -d "$SB/db" ]] && chmod u+rwx "$SB/db" 2>/dev/null
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
# the backup one-shot as logged by the mock (ERE): umask 077 in the container,
# the .partial name with its random suffix as $1
BK='--entrypoint sh relay -c umask 077; exec /app/haven backup "\$1" sh /app/backups/'
PART='\.partial-[0-9a-f]{16}$'
# the .partial path the backup run was given (host side)
partial_of() { grep -oE "/app/backups/[^ ]+\.partial[-0-9a-f]*$" "$MOCK_DOCKER_STATE_DIR/calls.log" | head -n1 | sed "s#^/app/backups/#$SB/backups/#"; }
good_payload() { export MOCK_RUN_WRITES=1 MOCK_RUN_PAYLOAD_FILE="$FIXTURES/good.zip"; }

# 1
@test "backup, relay running: stop < run backup /app/backups/<f> < start, verified zip in place" {
  relay_running
  good_payload
  run hv backup nightly.zip
  [ "$status" -eq 0 ]
  local s r t
  s="$(line_of 'docker-compose\.yml stop relay$')"
  r="$(line_of "docker-compose\\.yml run --rm --no-deps -T --name havenbk-relay-oneshot -v [^ ]*/backups:/app/backups ${BK}nightly\\.zip$PART")"
  t="$(line_of 'docker-compose\.yml start relay$')"
  [ -n "$s" ] && [ -n "$r" ] && [ -n "$t" ]
  (( s < r && r < t ))
  cmp "$FIXTURES/good.zip" "$SB/backups/nightly.zip"
  [ -z "$(compgen -G "$SB/backups/*.partial*")" ]
  [[ "$output" == *"Backup written: $SB/backups/nightly.zip ($(stat -c %s "$FIXTURES/good.zip") bytes, five entries verified with host unzip)."* ]]
  [[ "$output" == *"does not contain the media files in blossom/, your .env or the JSON lists"* ]]
}

# 2
@test "backup, relay stopped: no stop, no start" {
  good_payload
  run hv backup
  [ "$status" -eq 0 ]
  [ -n "$(line_of " run .* $BK")" ]
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
  r="$(line_of " run .* $BK")"
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
  local p
  p="$(partial_of)"
  [[ "$p" == "$SB/backups/x.zip.partial-"* ]]
  cmp "$FIXTURES/trunc.zip" "$p"
  [[ "$output" == *"is damaged"* ]]
  [[ "$output" == *"kept for inspection: $p"* ]]
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
  [ -n "$(line_of " ${BK}haven-backup-20260102-030405\\.zip$PART")" ]

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
  [ -n "$(line_of "^compose -f $SB/docker-compose\.tor\.yml run .* ${BK}t\.zip$PART")" ]
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
  [ -f "$(partial_of)" ]
}

# ---------- security audit findings F1-F7 ----------

# wait_started — the held mock `run` has begun (the relay is stopped by then)
wait_started() {
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -e "$MOCK_DOCKER_STATE_DIR/started" ]] && return 0
    sleep 0.05
  done
  return 1
}
relay_is_running() { grep -qxF havenbk-relay "$MOCK_DOCKER_STATE_DIR/running" 2>/dev/null; }

# F1. The mock applies the `umask NNN` it finds in the container's -c script to
# the file it writes, and the test pins its own umask to 022: the 0600 below
# can only come from the umask ./haven hands to the container. Without it the
# zip is 0644, as it was at 70d5039.
@test "F1: backups/ is created 0700 and the zip ends 0600 although the caller's umask is 022" {
  rm -rf "$SB/backups"
  relay_running
  good_payload
  umask 022
  run hv backup m.zip
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$SB/backups")" = 700 ]
  [ "$(stat -c %a "$SB/backups/m.zip")" = 600 ]
  [ -n "$(line_of " ${BK}m\.zip$PART")" ]
}

@test "F2: a group-writable backups/ is refused before any stop, for backup and for restore" {
  relay_running
  good_payload
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  chmod 770 "$SB/backups"
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"backups/ is writable by other accounts (mode 770)"* ]]
  [ -z "$(state_changes)" ]
  [ ! -e "$SB/backups/x.zip" ]
  run hv restore good.zip --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"backups/ is writable by other accounts (mode 770)"* ]]
  [ -z "$(state_changes)" ]
}

@test "F2: a .partial swapped for a symlink during the run: non-zero, target untouched, no *.zip symlink" {
  relay_running
  cp "$FIXTURES/good.zip" "$SB/db/victim.zip"
  local before
  before="$(stat -c '%i %s %Y' "$SB/db/victim.zip")"
  export MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=20
  "$SB/haven" backup x.zip </dev/null >"$TEST_DIR/out" 2>&1 &
  local pid=$! st=0 p
  wait_started
  p="$(partial_of)"
  [ -n "$p" ]
  # what another account with write access would plant: relative, so it lands
  # in db/ on the host and in the container alike
  ln -s ../db/victim.zip "$p"
  : > "$MOCK_DOCKER_STATE_DIR/release"
  wait "$pid" || st=$?
  cat "$TEST_DIR/out"
  [ "$st" -ne 0 ]
  cmp "$FIXTURES/good.zip" "$SB/db/victim.zip"
  [ "$(stat -c '%i %s %Y' "$SB/db/victim.zip")" = "$before" ]
  [ -z "$(find "$SB/backups" -name '*.zip' -type l)" ]
  [ ! -e "$SB/backups/x.zip" ] && [ ! -L "$SB/backups/x.zip" ]
  grep -q 'is a symbolic link' "$TEST_DIR/out"
  ! grep -q 'Backup written' "$TEST_DIR/out"
}

@test "F2: restore of a symlink is refused before any stop" {
  relay_running
  cp "$FIXTURES/good.zip" "$TEST_DIR/outside.zip"
  ln -s "$TEST_DIR/outside.zip" "$SB/backups/link.zip"
  run hv restore link.zip --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"link.zip is a symbolic link"* ]]
  [[ "$output" != *"Restore finished"* ]]
  [ -z "$(state_changes)" ]
}

# signal_case <signal> <verb args...> — runs ./haven in the background with a
# held one-shot, sends <signal> to ./haven alone once the relay is stopped, and
# leaves the exit status in SIG_ST.
signal_case() {
  local sig="$1"
  shift
  relay_running
  export MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=20
  "$SB/haven" "$@" </dev/null >"$TEST_DIR/out" 2>&1 &
  local pid=$!
  wait_started
  ! relay_is_running
  kill -s "$sig" "$pid"
  SIG_ST=0
  wait "$pid" || SIG_ST=$?
  cat "$TEST_DIR/out"
}
# the one-shot was stopped before the relay was started again
stopped_before_restart() {
  local o t
  o="$(line_of '^stop -t 10 havenbk-relay-oneshot$')"
  t="$(grep -n -E ' start relay$' "$MOCK_DOCKER_STATE_DIR/calls.log" | tail -n1 | cut -d: -f1)"
  [ -n "$o" ] && [ -n "$t" ] && (( o < t ))
}

@test "F3: SIGTERM during the held backup: one-shot stopped, relay restarted, state named, exit 143" {
  good_payload
  signal_case TERM backup s.zip
  [ "$SIG_ST" -eq 143 ]
  relay_is_running
  stopped_before_restart
  grep -q 'Received SIGTERM during the backup' "$TEST_DIR/out"
  grep -q 'INFO The relay is running\.' "$TEST_DIR/out"
}

@test "F3: SIGHUP during the held restore: one-shot stopped, relay restarted, state named, exit 129" {
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  signal_case HUP restore good.zip --yes
  [ "$SIG_ST" -eq 129 ]
  relay_is_running
  stopped_before_restart
  grep -q 'Received SIGHUP during the restore' "$TEST_DIR/out"
  grep -q 'INFO The relay is running\.' "$TEST_DIR/out"
}

@test "F3: SIGTERM during the held import: the import shares the guard" {
  signal_case TERM import
  [ "$SIG_ST" -eq 143 ]
  relay_is_running
  stopped_before_restart
  grep -q 'Received SIGTERM during the import' "$TEST_DIR/out"
}

# Ctrl-C. Background jobs of a non-interactive shell start with SIGINT
# ignored, and a shell cannot trap a signal it was started with ignored. The
# launcher resets SIGINT to the default, makes ./haven the leader of its own
# process group (setsid) and execs it (same pid); SIGINT then goes to that whole
# group, ./haven and the compose child alike, as a terminal sends it. The SigIgn
# mask of the pid is read back before the signal is sent, so the test knows the
# signal can arrive, and the trap's own message proves that it did.
@test "F3: SIGINT to the process group during the held backup (Ctrl-C): relay restarted, exit 130" {
  relay_running
  good_payload
  export MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=20
  python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    "$SB/haven" backup i.zip </dev/null >"$TEST_DIR/out" 2>&1 &
  local pid=$! st=0 mask
  wait_started
  mask="$(awk '/^SigIgn:/ {print $2}' "/proc/$pid/status")"
  [ -n "$mask" ]
  (( (16#$mask & 2) == 0 ))
  [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ]
  kill -s INT -- -"$pid"
  wait "$pid" || st=$?
  cat "$TEST_DIR/out"
  [ "$st" -eq 130 ]
  relay_is_running
  stopped_before_restart
  grep -q 'Received SIGINT during the backup' "$TEST_DIR/out"
}

@test "./haven start and restart refuse while a one-shot container exists" {
  printf 'havenbk-relay-oneshot\n' > "$MOCK_DOCKER_STATE_DIR/exited"
  run hv start
  [ "$status" -ne 0 ]
  [[ "$output" == *"one-shot container (backup, restore or import) exists: havenbk-relay-oneshot"* ]]
  [ -z "$(state_changes)" ]
  run hv restart
  [ "$status" -ne 0 ]
  [ -z "$(grep -E '^compose .* (down|up|start)( |$)' "$MOCK_DOCKER_STATE_DIR/calls.log")" ]
}

# last_word — the last non-empty output line
last_word() { printf '%s\n' "$output" | awk 'NF {l = $0} END {print l}'; }

@test "F4: the relay does not come back (start and up refused): backup, restore and import end non-zero with the warning last" {
  relay_running
  good_payload
  export MOCK_START_FAILS=1
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"The relay did not start again; it is NOT running"* ]]
  [[ "$(last_word)" == "WARN The relay is NOT running. Start it with './haven start'." ]]
  [ -n "$(line_of ' up -d$')" ]

  relay_running
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  run hv restore good.zip --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"The relay did not start again"* ]]
  [[ "$(last_word)" == "WARN The relay is NOT running"* ]]

  relay_running
  run hv import
  [ "$status" -ne 0 ]
  [[ "$output" == *"The relay did not start again"* ]]
  [[ "$(last_word)" == "WARN The relay is NOT running"* ]]
  [[ "$output" != *"OK Import finished"* ]]
}

@test "F5: an unreadable db/ (mode 000 and 300) counts as holding data: no tty, no --yes, no docker change" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any directory"
  relay_running
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  mkdir -p "$SB/db/private"
  printf 'x' > "$SB/db/private/MANIFEST"
  local m
  for m in 000 300; do
    : > "$MOCK_DOCKER_STATE_DIR/calls.log"
    chmod "$m" "$SB/db"
    run hv restore good.zip
    chmod 700 "$SB/db"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--yes"* ]]
    [ -z "$(state_changes)" ]
  done
}

@test "F6: start and restart are not blocked by a foreign-owned backups/" {
  # stat stand-in: backups/ reports another owner, everything else is real
  cat > "$TEST_DIR/bin/stat" <<'SH'
#!/usr/bin/env bash
last="${*: -1}"
if [[ "$last" == */backups && " $* " == *" %u "* ]]; then echo 4242; exit 0; fi
exec /usr/bin/env -u PATH /usr/bin/stat "$@"
SH
  chmod +x "$TEST_DIR/bin/stat"
  [ "$(stat -L -c %u "$SB/backups")" = 4242 ]
  run hv start
  [ "$status" -eq 0 ]
  [[ "$output" != *"backups/"* ]]
  [ -n "$(line_of ' up -d( |$)')" ]
  : > "$MOCK_DOCKER_STATE_DIR/calls.log"
  run hv restart
  [ "$status" -eq 0 ]
  [[ "$output" != *"backups/"* ]]
  [ -n "$(line_of ' up -d( |$)')" ]
  # backup itself still refuses that backups/
  run hv backup x.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"backups/ is owned by uid 4242"* ]]
}

@test "F7: escape text in a zip entry name or a file name in backups/ never reaches the output as an ESC byte" {
  python3 -I - "$SB/backups/evil.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for n in ("private", "chat", "outbox", "inbox", "blossom"):
        z.writestr(n + ".jsonl", "{}\n")
    z.writestr("\\033[2J.jsonl", "{}\n")
PY
  relay_running
  run hv restore evil.zip --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a complete Haven backup"* ]]
  [[ "$output" == *'\033[2J.jsonl'* ]]
  [[ "$output" != *$'\e'* ]]
  [ -z "$(state_changes)" ]

  : > "$SB/backups/"$'\e[2Jraw.zip'
  run hv restore missing.zip
  [ "$status" -ne 0 ]
  [[ "$output" == *"  ?[2Jraw.zip"* ]]
  [[ "$output" != *$'\e'* ]]
}

# ---------- second security audit: N1, N2 and the start-path gap ----------

# ignored_bit <pid> <signal number> — 0 when the signal is NOT ignored by <pid>
ignored_bit() {
  local mask
  mask="$(awk '/^SigIgn:/ {print $2}' "/proc/$1/status")"
  [ -n "$mask" ] || return 2
  printf '%d\n' $(( (16#$mask >> ($2 - 1)) & 1 ))
}

# pty_case <hangup|kill> <verb args...> — ./haven as session leader of a fresh
# pty (tests/pty-hangup.py) with a held one-shot; leaves the fixture's verdict
# ("exit <n>" or "signal <n>") in PTY_ST and the output in $TEST_DIR/pty.out.
pty_case() {
  local mode="$1"
  shift
  rm -f "$MOCK_DOCKER_STATE_DIR/started" "$MOCK_DOCKER_STATE_DIR/release"
  : > "$MOCK_DOCKER_STATE_DIR/calls.log"
  relay_running
  export MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=20
  PTY_ST="$(python3 -I "$REPO_ROOT/tests/pty-hangup.py" "$mode" "$MOCK_DOCKER_STATE_DIR" "$TEST_DIR/pty.out" "$SB/haven" "$@")"
  echo "pty $mode $*: $PTY_ST"
  cat "$TEST_DIR/pty.out"
  echo
  calls
}

@test "N1: terminal hangup during the held backup: one-shot stopped, relay restarted (control: SIGHUP, terminal open)" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is required for the pty fixture (tests/pty-hangup.py)"
  good_payload
  # control: the same signal on a terminal that still works — proves the
  # fixture delivers SIGHUP to ./haven and reads its output
  pty_case kill backup c.zip
  [ "$PTY_ST" = "signal 1" ]
  relay_is_running
  stopped_before_restart
  grep -q 'Received SIGHUP during the backup' "$TEST_DIR/pty.out"
  grep -q 'INFO.* The relay is running\.' "$TEST_DIR/pty.out"   # colours: it is a tty
  # the hangup: SIGHUP, and every write to the terminal fails with EIO
  pty_case hangup backup h.zip
  [ "$PTY_ST" = "signal 1" ]
  relay_is_running
  stopped_before_restart
}

@test "N1: terminal hangup during the held restore and the held import: relay restarted" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is required for the pty fixture (tests/pty-hangup.py)"
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  pty_case hangup restore good.zip --yes
  [ "$PTY_ST" = "signal 1" ]
  relay_is_running
  stopped_before_restart
  pty_case hangup import
  [ "$PTY_ST" = "signal 1" ]
  relay_is_running
  stopped_before_restart
}

# Ctrl-C with the output going through a pipe: the terminal sends SIGINT to the
# whole foreground group, so the reader (cat) dies together with the signal and
# every write of the handler to stdout hits a closed pipe. The launcher resets
# SIGINT and SIGPIPE to their defaults, makes itself a group leader, forks the
# reader into that group and execs ./haven (same pid) with stdout on the pipe.
@test "N1: SIGINT to the process group while stdout goes through a pipe whose reader dies: relay restarted, exit 130" {
  relay_running
  good_payload
  export MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=20
  python3 -I -c '
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.setsid()
r, w = os.pipe()
if os.fork() == 0:
    os.dup2(r, 0); os.close(r); os.close(w)
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(fd, 1)
    os.execvp("cat", ["cat"])
os.close(r); os.dup2(w, 1); os.close(w)
os.execv(sys.argv[2], sys.argv[2:])
' "$TEST_DIR/piped" "$SB/haven" backup p.zip </dev/null 2>"$TEST_DIR/err" &
  local pid=$! st=0 reader
  wait_started
  [ "$(ignored_bit "$pid" 2)" = 0 ]    # SIGINT reaches ./haven
  [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ]
  reader="$(pgrep -P "$pid" -x cat)"
  [ -n "$reader" ]
  # ./haven itself ignores SIGPIPE by now (the guard); the reader was forked
  # after the launcher's reset, so its mask shows what ./haven started with
  [ "$(ignored_bit "$reader" 13)" = 0 ]
  [ "$(ignored_bit "$reader" 2)" = 0 ]
  kill -s INT -- -"$pid"
  wait "$pid" || st=$?
  echo "exit $st"; cat "$TEST_DIR/piped" "$TEST_DIR/err"; calls
  ! kill -0 "$reader" 2>/dev/null      # the reader is gone
  [ "$st" -eq 130 ]
  relay_is_running
  stopped_before_restart
}

# No signal at all: the reader goes away while the one-shot runs, and the
# one-shot then ends normally. Decided exit status: 141. Inside the guarded
# window SIGPIPE is ignored, so the relay restart cannot be cut short; after the
# window the disposition is the default again and the next write ends ./haven
# by SIGPIPE, as any command writing into a closed pipe does — the caller learns
# that output was lost. The backup itself is complete by then (verified,
# renamed), and the relay runs.
@test "N1: the output reader goes away while the one-shot runs, no signal: relay restarted, backup complete, exit 141" {
  relay_running
  good_payload
  export MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=20
  mkfifo "$TEST_DIR/fifo"
  cat "$TEST_DIR/fifo" > "$TEST_DIR/piped" &
  local rpid=$!
  python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGPIPE, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$SB/haven" backup g.zip </dev/null >"$TEST_DIR/fifo" 2>"$TEST_DIR/err" &
  local pid=$! st=0
  wait_started
  # (SIGPIPE cannot be checked here: ./haven ignores it inside the guard; the
  # exit status 141 asserted below needs the default disposition on entry)
  kill -KILL "$rpid"
  wait "$rpid" || true
  : > "$MOCK_DOCKER_STATE_DIR/release"
  wait "$pid" || st=$?
  echo "exit $st"; cat "$TEST_DIR/piped" "$TEST_DIR/err"; calls
  relay_is_running
  local r t
  r="$(line_of " run .* $BK")"
  t="$(line_of ' start relay$')"
  [ -n "$r" ] && [ -n "$t" ] && (( r < t ))
  cmp "$FIXTURES/good.zip" "$SB/backups/g.zip"
  [ "$st" -eq 141 ]
}

# TERM while `compose stop relay` is still running (a 2 s stop): the trap fires
# when the stop returns, inside relay_stop_for_oneshot.
@test "N2: SIGTERM during a slow relay stop: the handler's messages reach the original output; with a failing start the NOT-running warning too" {
  local start_fails
  for start_fails in 0 1; do
    : > "$MOCK_DOCKER_STATE_DIR/calls.log"
    relay_running
    export MOCK_STOP_SLEEP=2 MOCK_START_FAILS="$start_fails"
    "$SB/haven" backup s.zip </dev/null >"$TEST_DIR/out" 2>&1 &
    local pid=$! st=0 i
    for ((i = 0; i < 100; i++)); do
      [ -n "$(line_of ' stop relay$')" ] && break
      sleep 0.05
    done
    [ -n "$(line_of ' stop relay$')" ]
    sleep 0.3
    kill -s TERM "$pid"
    wait "$pid" || st=$?
    echo "MOCK_START_FAILS=$start_fails exit $st"; cat "$TEST_DIR/out"; calls
    [ "$st" -eq 143 ]
    [ -z "$(line_of ' run ')" ]
    grep -q 'Received SIGTERM during the backup' "$TEST_DIR/out"
    if [ "$start_fails" = 0 ]; then
      relay_is_running
      grep -q 'INFO The relay is running\.' "$TEST_DIR/out"
    else
      ! relay_is_running
      grep -q 'The relay did not start again; it is NOT running' "$TEST_DIR/out"
      grep -q "WARN The relay is NOT running. Start it with './haven start'." "$TEST_DIR/out"
    fi
  done
}

# The TUI menu (Start Docker, Start Tor, Restart) and the restart after an .env
# edit, driven through the real handlers with the dialogs stubbed. The .env
# restart runs with errexit active, as inside the TUI: a refusal must not end it.
@test "gap: TUI Start/Restart and the restart after an .env edit refuse while a one-shot container exists; nothing is started" {
  relay_running
  printf 'havenbk-relay-oneshot\n' > "$MOCK_DOCKER_STATE_DIR/exited"
  run bash -c '
    source "$1"
    set +e
    DOCKER_COMPOSE=(docker compose)
    TUI_ACTIVE=1 FOLLOW_LOGS=0 TUI_VIEW=main TUI_SEL=0
    tui_confirm() { return 0; }
    tui_require_docker() { return 0; }
    tui_refresh_logs_view() { :; }
    tui_message() { printf "MESSAGE[%s]\n%s\nEND\n" "$1" "$2"; }
    for id in start_plain start_tor restart; do
      MENU_IDS=("$id")
      echo "== $id"
      tui_handle_enter
    done
    echo "== env"
    set -e
    restart_after_env_change
    echo "env rc=$?"
  ' _ "$SB/haven"
  echo "$output"
  calls
  [ "$status" -eq 0 ]
  [ -z "$(grep -E '^compose .* (up|start|down|stop|restart)( |$)' "$MOCK_DOCKER_STATE_DIR/calls.log")" ]
  local refusal='one-shot container (backup, restore or import) exists: havenbk-relay-oneshot'
  local id
  for id in start_plain start_tor restart; do
    printf '%s\n' "$output" | awk -v id="== $id" '$0 == id {on = 1; next} /^== / {on = 0} on' > "$TEST_DIR/block"
    grep -q '^MESSAGE\[\(Start\|Restart\)\]$' "$TEST_DIR/block"
    grep -qF "$refusal" "$TEST_DIR/block"
  done
  printf '%s\n' "$output" | awk '$0 == "== env" {on = 1; next} on' > "$TEST_DIR/block"
  grep -q '^MESSAGE\[Restart\]$' "$TEST_DIR/block"
  grep -qF '.env was saved; the restart to apply it is skipped.' "$TEST_DIR/block"
  grep -qF "$refusal" "$TEST_DIR/block"
  grep -qx 'env rc=0' "$TEST_DIR/block"
}
