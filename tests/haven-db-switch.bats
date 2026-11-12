#!/usr/bin/env bats
# `./haven db-switch <badger|lmdb>` and `./haven db-switch --rollback` against
# the scripted docker mock (tests/mock/docker, MOCK_DOCKER_STATE_DIR). Each test
# runs a copy of ./haven inside its own sandbox, so db/, backups/ and .env are
# the sandbox's, never the checkout's.
# The database is faked by file names (badger: MANIFEST, *.vlog, KEYREGISTRY;
# lmdb: data.mdb, lock.mdb); the mock writes the target engine's files into
# db/ on a restore (MOCK_DB_DIR) and a real zip on a backup.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TS=20260102-030405
DIRS="private chat outbox inbox blossom"

setup_file() {
  export FIXTURES="$BATS_FILE_TMPDIR/fixtures"
  mkdir -p "$FIXTURES"
  python3 -I - "$FIXTURES" <<'PY'
import sys, zipfile
d = sys.argv[1]
for name, extra in (("good", ""), ("other", "x")):
    with zipfile.ZipFile(d + "/" + name + ".zip", "w", zipfile.ZIP_DEFLATED) as z:
        for n in ("private", "chat", "outbox", "inbox", "blossom"):
            z.writestr(n + ".jsonl", ("{\"id\":\"%s%s\"}\n" % (n, extra)) * 400)
PY
}

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sandbox"
  mkdir -p "$SB/db" "$SB/blossom" "$TEST_DIR/bin"
  mkdir -m 700 "$SB/backups"
  cp "$REPO_ROOT/haven" "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/docker-compose.tor.yml" "$SB/"
  printf '*\n!.gitignore\n' > "$SB/db/.gitignore"
  local f
  for f in relays_import relays_blastr blacklisted_npubs whitelisted_npubs; do
    printf '[]\n' > "$SB/$f.json"
    printf '[]\n' > "$SB/$f.example.json"
  done
  printf 'DOCKER_UID=%s\nDOCKER_GID=%s\nDB_ENGINE="badger" # badger, lmdb\nRELAY_PORT=3355\n' "$(id -u)" "$(id -g)" > "$SB/.env"

  # pinned clock for the time stamps of db-switch ($TEST_DIR/now moves it)
  export NOW_FILE="$TEST_DIR/now"
  cat > "$TEST_DIR/bin/date" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%Y%m%d-%H%M%S" ]]; then cat "$NOW_FILE" 2>/dev/null || echo "20260102-030405"; exit 0; fi
exec /usr/bin/env -u PATH /bin/date "$@"
SH
  chmod +x "$TEST_DIR/bin/date"

  PATH="$TEST_DIR/bin:$REPO_ROOT/tests/mock:$PATH"
  export MOCK_DOCKER_STATE_DIR="$TEST_DIR/state"
  mkdir -p "$MOCK_DOCKER_STATE_DIR"
  unset MOCK_STOP_FAILS MOCK_RUN_EXIT MOCK_FAIL_AT MOCK_RUN_HOLD MOCK_HOLD_MAX MOCK_HOLD_AT \
    MOCK_RUN_PAYLOAD MOCK_PAYLOAD_AT MOCK_PAYLOAD_AT_FILE HAVEN_HOST_UNZIP \
    MOCK_START_FAILS MOCK_STOP_SLEEP HAVEN_TEST_SWITCH_HOOK
  export HAVEN_CONTAINER_NAME=havensw-relay
  export MOCK_RUN_WRITES=1 MOCK_RUN_PAYLOAD_FILE="$FIXTURES/good.zip" MOCK_DB_DIR="$SB/db"
}

teardown() {
  [[ -n "${MOCK_DOCKER_STATE_DIR:-}" && -d "$MOCK_DOCKER_STATE_DIR" ]] && : > "$MOCK_DOCKER_STATE_DIR/release"
  [[ -n "${TEST_DIR:-}" ]] && chmod -R u+rwX "$TEST_DIR" 2>/dev/null
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

relay_running() { printf 'havensw-relay\n' > "$MOCK_DOCKER_STATE_DIR/running"; }
relay_is_running() { grep -qxF havensw-relay "$MOCK_DOCKER_STATE_DIR/running" 2>/dev/null; }
hv() { "$SB/haven" "$@" </dev/null; }
calls() { cat "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null; }
line_of() { grep -n -m1 -E -- "$1" "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null | cut -d: -f1; }
state_changes() { grep -E '^compose .* (stop|start|up|down|run|restart|rm)( |$)' "$MOCK_DOCKER_STATE_DIR/calls.log" 2>/dev/null; }
result_line() { printf '%s\n' "$output" | grep -E '^::result ' | tail -n1; }

# fake_engine <engine> [base] — the five directories with that engine's files,
# every file with its own content
fake_engine() {
  local e="$1" base="${2:-$SB/db}" n
  for n in $DIRS; do
    mkdir -p "$base/$n"
    if [[ "$e" == badger ]]; then
      printf 'orig manifest %s\n' "$n" > "$base/$n/MANIFEST"
      printf 'orig vlog %s\n' "$n" > "$base/$n/000001.vlog"
      printf 'orig keys %s\n' "$n" > "$base/$n/KEYREGISTRY"
    else
      printf 'orig data %s\n' "$n" > "$base/$n/data.mdb"
      printf 'orig lock %s\n' "$n" > "$base/$n/lock.mdb"
    fi
  done
}

# the engine on disk, judged independently of ./haven
disk_engine() {
  local n b=0 l=0
  for n in $DIRS; do
    { [ -e "$SB/db/$n/MANIFEST" ] || [ -e "$SB/db/$n/000001.vlog" ]; } && b=1
    [ -e "$SB/db/$n/data.mdb" ] && l=1
  done
  if ((b && l)); then echo mixed; elif ((b)); then echo badger; elif ((l)); then echo lmdb; else echo none; fi
}
# DB_ENGINE in .env without quotes and comment, "unset" without a line
env_engine() {
  local v
  v="$(sed -n 's/^DB_ENGINE=//p' "$SB/.env" | sed -e 's/[[:space:]]*#.*//' -e 's/"//g')"
  if grep -q '^DB_ENGINE=' "$SB/.env"; then echo "$v"; else echo unset; fi
}

# hash and path of every file under db/ (the marker excluded: it is ./haven's own)
db_files() {
  (cd "$SB/db" && find . -type f ! -name '.switch-in-progress*' -print0 | sort -z | xargs -0 -r sha1sum)
}
snapshot() { db_files > "$TEST_DIR/before.files"; cp -p "$SB/.env" "$TEST_DIR/env.before"; }
# 14. every file that was under db/ is still there with the same content: at
# the same path or inside one of the documented directories
# (.pre-switch-*, .failed-*, .post-switch-*)
nothing_lost() {
  db_files > "$TEST_DIR/after.files"
  python3 -I - "$TEST_DIR/before.files" "$TEST_DIR/after.files" <<'PY'
import re, sys
from collections import Counter
strip = re.compile(r"^\./(?:\.(?:pre-switch|failed|post-switch)-[^/]+/)?")
def load(p):
    c = Counter()
    for line in open(p):
        h, path = line.rstrip("\n").split("  ", 1)
        c[(h, strip.sub("", path))] += 1
    return c
before, after = load(sys.argv[1]), load(sys.argv[2])
lost = before - after
for (h, p), n in lost.items():
    print("LOST: %s (%s) x%d" % (p, h, n))
sys.exit(1 if lost else 0)
PY
}
# the original badger files are at their original paths again
originals_in_place() {
  local h p
  while read -r h p; do
    [ -f "$SB/db/$p" ] || { echo "missing $p"; return 1; }
    [ "$(sha1sum < "$SB/db/$p" | cut -d' ' -f1)" = "$h" ] || { echo "changed $p"; return 1; }
  done < <(sed 's#  \./#  #' "$TEST_DIR/before.files" | grep -v '^[0-9a-f]*  \.gitignore$')
}

# --- the invariants of every injected failure (case 9) ---
invariants() { # <step3-completed:0|1> <after-move:0|1> <expected result>
  echo "$output"
  echo "--- calls"; calls
  [ "$status" -ne 0 ]
  [ "$(env_engine)" = "$(disk_engine)" ]
  if [ "$1" = 1 ]; then [ -f "$SB/backups/haven-pre-switch-lmdb-$TS.zip" ]; fi
  if [ "$2" = 1 ]; then originals_in_place; fi
  [ "$(result_line)" = "::result $3" ]
  [ ! -e "$SB/db/.switch-in-progress" ]
  [ -f "$SB/db/.gitignore" ]
  nothing_lost
}

BK_PRE="haven-pre-switch-lmdb-$TS\\.zip"
BK_POST="haven-post-switch-lmdb-$TS\\.zip"

# 1
@test "1 happy path badger->lmdb, relay running: stop < backup < restore < backup < up -d (recreate); .env lmdb; old dirs stashed; marker gone" {
  fake_engine badger
  relay_running
  snapshot
  run hv db-switch lmdb --yes
  echo "$output"; calls
  [ "$status" -eq 0 ]
  local s r1 r2 r3 t
  s="$(line_of '^compose -f [^ ]*docker-compose\.yml stop relay$')"
  r1="$(line_of " run --rm --no-deps -T --name havensw-relay-oneshot -v [^ ]*/backups:/app/backups -e DB_ENGINE=badger --entrypoint sh relay -c umask 077; exec /app/haven backup \"\\\$1\" sh /app/backups/$BK_PRE\\.partial-[0-9a-f]{16}$")"
  r2="$(line_of " run --rm --no-deps -T --name havensw-relay-oneshot -v [^ ]*/backups:/app/backups -e DB_ENGINE=lmdb --entrypoint /app/haven relay restore /app/backups/$BK_PRE$")"
  r3="$(line_of " run .* -e DB_ENGINE=lmdb --entrypoint sh relay -c .* /app/backups/$BK_POST\\.partial-[0-9a-f]{16}$")"
  t="$(line_of ' up -d relay$')"
  [ -n "$s" ] && [ -n "$r1" ] && [ -n "$r2" ] && [ -n "$r3" ] && [ -n "$t" ]
  (( s < r1 && r1 < r2 && r2 < r3 && r3 < t ))
  # recreated, not `compose start`: the old container still carries the old DB_ENGINE
  [ -z "$(line_of ' start relay$')" ]
  [ "$(env_engine)" = lmdb ]
  [ "$(disk_engine)" = lmdb ]
  local n
  for n in $DIRS; do
    [ -f "$SB/db/.pre-switch-badger-$TS/$n/MANIFEST" ]
    [ -f "$SB/db/$n/data.mdb" ]
  done
  [ ! -e "$SB/db/.switch-in-progress" ]
  [ -f "$SB/db/.gitignore" ]
  [ "$(cat "$SB/db/.gitignore")" = $'*\n!.gitignore' ]
  [ -f "$SB/backups/haven-pre-switch-lmdb-$TS.zip" ]
  [ -f "$SB/backups/haven-post-switch-lmdb-$TS.zip" ]
  relay_is_running
  [ "$(result_line)" = "::result ok" ]
  [ "$(printf '%s\n' "$output" | grep -E '^::step ' | tr '\n' '|')" = "::step 1/7 preflight|::step 2/7 stop|::step 3/7 backup|::step 4/7 move|::step 5/7 config|::step 6/7 restore|::step 7/7 start|" ]
  [[ "$output" == *"db/.pre-switch-badger-$TS/"* ]]
  [[ "$output" == *"db-switch --rollback"* ]]
  [[ "$output" == *"never deletes them"* ]]
  # quoting of the old value kept
  grep -qx 'DB_ENGINE="lmdb"' "$SB/.env"
  nothing_lost
}

# 2
@test "2 happy path with the relay stopped: no stop, no start" {
  fake_engine badger
  snapshot
  run hv db-switch lmdb --yes
  echo "$output"; calls
  [ "$status" -eq 0 ]
  [ -z "$(line_of ' stop ')" ]
  [ -z "$(line_of ' (start|up) ')" ]
  [ -n "$(line_of ' relay restore ')" ]
  [ "$(env_engine)" = lmdb ] && [ "$(disk_engine)" = lmdb ]
  [ "$(result_line)" = "::result ok" ]
  nothing_lost
}

# 3
@test "3 same engine on disk as target: no docker state change, .env byte-identical" {
  fake_engine badger
  relay_running
  snapshot
  run hv db-switch badger --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already holds badger data"* ]]
  [ -z "$(state_changes)" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  [ "$(result_line)" = "::result failed" ]
  nothing_lost
}

# 4
@test "4 mixed directories: refused, named, no docker state change" {
  fake_engine badger
  printf 'x' > "$SB/db/chat/data.mdb"
  printf 'x' > "$SB/db/inbox/lock.mdb"
  relay_running
  snapshot
  run hv db-switch lmdb --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"files of both engines in: chat inbox"* ]]
  [[ "$output" == *"Decide which engine holds the data"* ]]
  [ -z "$(state_changes)" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  nothing_lost
}

# 5
@test "5 invalid arguments (lmbd, BADGER, empty, two engines, engine with --rollback): rc!=0, .env identical, no state change" {
  fake_engine badger
  relay_running
  snapshot
  local a
  for a in "lmbd" "BADGER" "" "badger lmdb" "lmdb --rollback"; do
    : > "$MOCK_DOCKER_STATE_DIR/calls.log"
    if [[ "$a" == *" "* ]]; then run hv db-switch $a --yes; else run hv db-switch "$a" --yes; fi
    echo "[$a] rc=$status $output"
    [ "$status" -ne 0 ]
    [ -z "$(state_changes)" ]
    cmp "$TEST_DIR/env.before" "$SB/.env"
  done
  run hv db-switch
  [ "$status" -ne 0 ]
  [ -z "$(state_changes)" ]
  nothing_lost
}

# 6
@test "6 DB_ENGINE unset or unknown in .env with badger on disk: the disk decides and says what it found" {
  local v
  for v in unset foo; do
    rm -rf "$SB/db/"* "$SB/db/".pre-switch-* "$SB/backups/"* "$MOCK_DOCKER_STATE_DIR/calls.log"
    fake_engine badger
    if [ "$v" = unset ]; then
      printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" > "$SB/.env"
    else
      printf 'DOCKER_UID=%s\nDOCKER_GID=%s\nDB_ENGINE=foo\n' "$(id -u)" "$(id -g)" > "$SB/.env"
    fi
    snapshot
    run hv db-switch lmdb --yes
    echo "[$v] $output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Found badger data in db/ (private chat outbox inbox blossom)"* ]]
    [[ "$output" == *"the disk decides"* ]]
    if [ "$v" = unset ]; then
      [[ "$output" == *"DB_ENGINE is not set in .env"* ]]
    else
      [[ "$output" == *"DB_ENGINE in .env is 'foo'"* ]]
    fi
    # the backup ran on the engine found on disk, not on upstream's lmdb default
    [ -n "$(line_of ' -e DB_ENGINE=badger --entrypoint sh relay ')" ]
    [ "$(env_engine)" = lmdb ] && [ "$(disk_engine)" = lmdb ]
    nothing_lost
  done
}

# 7
@test "7 empty db/: no docker state change; only .env needs changing" {
  relay_running
  snapshot
  run hv db-switch lmdb --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only .env needs changing"* ]]
  [ -z "$(state_changes)" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  [ -f "$SB/db/.gitignore" ]
}

# 8
@test "8 no tty and no --yes: refused before any stop" {
  fake_engine badger
  relay_running
  snapshot
  run hv db-switch lmdb
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"badger to lmdb"* ]]
  [[ "$output" == *"offline for the duration"* ]]
  [[ "$output" == *"db/.pre-switch-badger-$TS/"* ]]
  [ -z "$(state_changes)" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  nothing_lost
}

# 9 — one failure per step
@test "9a backup one-shot fails: nothing changed, relay back, result failed" {
  fake_engine badger
  relay_running
  snapshot
  export MOCK_FAIL_AT=1
  run hv db-switch lmdb --yes
  invariants 0 1 failed
  [ ! -e "$SB/backups/haven-pre-switch-lmdb-$TS.zip" ]
  [ -z "$(line_of ' relay restore ')" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  relay_is_running
  [[ "$output" == *"Nothing was changed"* ]]
}

@test "9b move fails (one directory cannot be moved): rolled back, originals in place, relay back" {
  [ "$(id -u)" -ne 0 ] || skip "root can move any directory"
  fake_engine badger
  relay_running
  snapshot
  chmod 500 "$SB/db/inbox"
  run hv db-switch lmdb --yes
  invariants 1 1 rolled-back
  [[ "$output" == *"could not move db/inbox"* ]]
  [ -z "$(line_of ' relay restore ')" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  [ ! -e "$SB/db/.pre-switch-badger-$TS" ]
  relay_is_running
}

@test "9c .env write fails (read-only .env): rolled back, .env untouched" {
  [ "$(id -u)" -ne 0 ] || skip "root writes a read-only file"
  fake_engine badger
  relay_running
  snapshot
  chmod 444 "$SB/.env"
  run hv db-switch lmdb --yes
  invariants 1 1 rolled-back
  [[ "$output" == *".env is not writable"* ]]
  [ -z "$(line_of ' relay restore ')" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  relay_is_running
}

@test "9d restore one-shot fails with a partial database: rolled back, partial set aside in db/.failed-<ts>/" {
  fake_engine badger
  relay_running
  snapshot
  export MOCK_FAIL_AT=2
  run hv db-switch lmdb --yes
  invariants 1 1 rolled-back
  [[ "$output" == *"the restore exited with status 1"* ]]
  [ -f "$SB/db/.failed-$TS/private/data.mdb" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  relay_is_running
  local r t
  r="$(line_of ' relay restore ')"
  t="$(line_of ' up -d relay$')"
  [ -n "$r" ] && [ -n "$t" ] && (( r < t ))
}

@test "9e CRC mismatch (second backup differs): rolled back" {
  fake_engine badger
  relay_running
  snapshot
  export MOCK_PAYLOAD_AT=3 MOCK_PAYLOAD_AT_FILE="$FIXTURES/other.zip"
  run hv db-switch lmdb --yes
  invariants 1 1 rolled-back
  [[ "$output" == *"differs from the backup of the old one"* ]]
  [ -f "$SB/db/.failed-$TS/chat/data.mdb" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  relay_is_running
}

@test "9f relay start fails: rolled back, start attempted again on the old engine, relay NOT running said" {
  fake_engine badger
  relay_running
  snapshot
  export MOCK_START_FAILS=1
  run hv db-switch lmdb --yes
  invariants 1 1 rolled-back
  [[ "$output" == *"the relay did not start on lmdb"* ]]
  [[ "$output" == *"it is NOT running"* ]]
  [ "$(grep -cE ' up -d relay$' "$MOCK_DOCKER_STATE_DIR/calls.log")" -eq 2 ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  ! relay_is_running
}

# 10
wait_started() {
  local i
  for ((i = 0; i < 200; i++)); do
    [[ -e "$MOCK_DOCKER_STATE_DIR/started" ]] && return 0
    sleep 0.05
  done
  return 1
}

@test "10a SIGTERM during the held restore one-shot: rolled back, relay running, marker gone" {
  fake_engine badger
  relay_running
  snapshot
  export MOCK_RUN_HOLD=1 MOCK_HOLD_AT=2 MOCK_HOLD_MAX=20
  "$SB/haven" db-switch lmdb --yes </dev/null >"$TEST_DIR/out" 2>&1 &
  local pid=$! st=0
  wait_started
  ! relay_is_running
  [ -e "$SB/db/.switch-in-progress" ]
  kill -s TERM "$pid"
  wait "$pid" || st=$?
  output="$(cat "$TEST_DIR/out")"
  echo "$output"; calls
  [ "$st" -eq 143 ]
  relay_is_running
  [ ! -e "$SB/db/.switch-in-progress" ]
  [ "$(env_engine)" = badger ] && [ "$(disk_engine)" = badger ]
  originals_in_place
  [ "$(result_line)" = "::result rolled-back" ]
  grep -q 'Received SIGTERM during the engine switch' "$TEST_DIR/out"
  nothing_lost
}

@test "10b terminal hangup (pty) during the held restore one-shot: rolled back, relay running, marker gone" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is required for the pty fixture"
  fake_engine badger
  relay_running
  snapshot
  export MOCK_RUN_HOLD=1 MOCK_HOLD_AT=2 MOCK_HOLD_MAX=20
  local st
  st="$(python3 -I "$REPO_ROOT/tests/pty-hangup.py" hangup "$MOCK_DOCKER_STATE_DIR" "$TEST_DIR/pty.out" "$SB/haven" db-switch lmdb --yes)"
  echo "pty: $st"; cat "$TEST_DIR/pty.out"; calls
  [ "$st" = "signal 1" ]
  relay_is_running
  [ ! -e "$SB/db/.switch-in-progress" ]
  [ "$(env_engine)" = badger ] && [ "$(disk_engine)" = badger ]
  originals_in_place
  nothing_lost
}

# 11
@test "11 marker present: start, restart, the TUI start paths (and backup, restore, import) refuse and name the rollback" {
  fake_engine badger
  printf 'kind=switch\n' > "$SB/db/.switch-in-progress"
  run hv start
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"./haven db-switch --rollback"* ]]
  [ -z "$(state_changes)" ]
  run hv restart
  [ "$status" -ne 0 ]
  [[ "$output" == *"db-switch --rollback"* ]]
  [ -z "$(state_changes)" ]
  # the one-shot verbs too: they would read or write a half-moved db/
  cp "$FIXTURES/good.zip" "$SB/backups/good.zip"
  local v
  for v in "backup x.zip" "restore good.zip --yes" "import"; do
    run hv $v
    echo "[$v] $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"db-switch --rollback"* ]]
    [ -z "$(state_changes)" ]
  done

  relay_running
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
  echo "$output"; calls
  [ "$status" -eq 0 ]
  [ -z "$(grep -E '^compose .* (up|start|down|stop|restart)( |$)' "$MOCK_DOCKER_STATE_DIR/calls.log")" ]
  local id
  for id in start_plain start_tor restart env; do
    printf '%s\n' "$output" | awk -v id="== $id" '$0 == id {on = 1; next} /^== / {on = 0} on' > "$TEST_DIR/block"
    grep -q '^MESSAGE\[\(Start\|Restart\)\]$' "$TEST_DIR/block"
    grep -qF "db-switch --rollback" "$TEST_DIR/block"
  done
}

# 12 — markers as db-switch writes them, at every recorded step
make_state() { # <step> <relay_was_running>
  local step="$1" n moved="$DIRS"
  mkdir -p "$SB/db/.pre-switch-badger-$TS"
  [ "$step" = move ] && moved="private chat"
  for n in $moved; do mv "$SB/db/$n" "$SB/db/.pre-switch-badger-$TS/$n"; done
  case "$step" in
    config|restored|verified|start) sed -i 's/^DB_ENGINE=.*/DB_ENGINE="lmdb"/' "$SB/.env" ;;
  esac
  case "$step" in
    restored|verified|start)
      for n in $DIRS; do mkdir -p "$SB/db/$n"; printf 'new %s\n' "$n" > "$SB/db/$n/data.mdb"; done ;;
  esac
  printf 'kind=switch\nsource=badger\ntarget=lmdb\nstarted=%s\nbackup=haven-pre-switch-lmdb-%s.zip\nstash=.pre-switch-badger-%s\naside=\ndirs=%s\nrelay_was_running=%s\nenv_set=1\nenv_line=DB_ENGINE="badger" # badger, lmdb\nstep=%s\n' \
    "$TS" "$TS" "$TS" "$DIRS" "$2" "$step" > "$SB/db/.switch-in-progress"
}

@test "12 --rollback with a marker at each recorded step restores the original layout; twice is harmless" {
  local step was
  for step in move moved config restored verified start; do
    rm -rf "$SB/db/"* "$SB/db/".pre-switch-* "$SB/db/".failed-* "$SB/db/.switch-in-progress"
    : > "$MOCK_DOCKER_STATE_DIR/calls.log"
    : > "$MOCK_DOCKER_STATE_DIR/running"
    printf 'DOCKER_UID=%s\nDOCKER_GID=%s\nDB_ENGINE="badger" # badger, lmdb\nRELAY_PORT=3355\n' "$(id -u)" "$(id -g)" > "$SB/.env"
    fake_engine badger
    snapshot
    was=0
    [ "$step" = restored ] && was=1
    make_state "$step" "$was"
    run hv db-switch --rollback
    echo "[$step] $output"
    [ "$status" -eq 0 ]
    [ "$(result_line)" = "::result rolled-back" ]
    [ ! -e "$SB/db/.switch-in-progress" ]
    originals_in_place
    cmp "$TEST_DIR/env.before" "$SB/.env"
    [ "$(disk_engine)" = badger ]
    [ ! -e "$SB/db/.pre-switch-badger-$TS" ]
    if [ "$was" = 1 ]; then relay_is_running; else [ -z "$(line_of ' (start|up) ')" ]; fi
    nothing_lost
    # again: nothing left to do, nothing changes
    db_files > "$TEST_DIR/mid.files"
    run hv db-switch --rollback
    echo "[$step again] $output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to roll back"* ]]
    db_files | cmp - "$TEST_DIR/mid.files"
    cmp "$TEST_DIR/env.before" "$SB/.env"
  done
}

# 13
@test "13 --rollback without a marker undoes the last completed switch and keeps the post-switch directories" {
  fake_engine badger
  relay_running
  snapshot
  run hv db-switch lmdb --yes
  [ "$status" -eq 0 ]
  printf 'new event\n' > "$SB/db/chat/new-since-switch.log"
  db_files > "$TEST_DIR/before.files"   # the post-switch file must survive too
  : > "$MOCK_DOCKER_STATE_DIR/calls.log"
  run hv db-switch --rollback
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]]
  [ -z "$(state_changes)" ]
  run hv db-switch --rollback --yes
  echo "$output"; calls
  [ "$status" -eq 0 ]
  [ "$(result_line)" = "::result rolled-back" ]
  [[ "$output" == *"NOT merged back"* ]]
  [ "$(env_engine)" = badger ] && [ "$(disk_engine)" = badger ]
  local n
  for n in $DIRS; do
    [ -f "$SB/db/.post-switch-lmdb-$TS/$n/data.mdb" ]
    [ "$(cat "$SB/db/$n/MANIFEST")" = "orig manifest $n" ]
  done
  [ -f "$SB/db/.post-switch-lmdb-$TS/chat/new-since-switch.log" ]
  [ ! -e "$SB/db/.pre-switch-badger-$TS" ]
  [ ! -e "$SB/db/.switch-in-progress" ]
  relay_is_running
  local s t
  s="$(line_of ' stop relay$')"; t="$(line_of ' up -d relay$')"
  [ -n "$s" ] && [ -n "$t" ] && (( s < t ))
  nothing_lost
}

# 14
@test "14 nothing is ever deleted: switch, undo, failed switch — every file of db/ survives" {
  fake_engine badger
  relay_running
  snapshot
  run hv db-switch lmdb --yes
  [ "$status" -eq 0 ]
  nothing_lost
  run hv db-switch --rollback --yes
  [ "$status" -eq 0 ]
  nothing_lost
  db_files > "$TEST_DIR/before.files"
  echo 20260102-040000 > "$NOW_FILE"
  export MOCK_FAIL_AT=5   # run 4 = backup, run 5 = restore of the second switch
  run hv db-switch lmdb --yes
  echo "$output"
  [ "$status" -ne 0 ]
  [ "$(result_line)" = "::result rolled-back" ]
  nothing_lost
}

# 15
@test "15 validate_env_value DB_ENGINE warns when db/ holds the other engine (control: same engine, empty db/)" {
  fake_engine badger
  run bash -c 'source "$1"; set +e; validate_env_value DB_ENGINE lmdb; echo "rc=$? warn=$VALIDATION_WARNING"' _ "$SB/haven"
  echo "$output"
  [[ "$output" == "rc=0 warn=db/ holds badger data: with DB_ENGINE=lmdb the relay will appear empty"* ]]
  [[ "$output" == *"keep DB_ENGINE=badger and run '"*" db-switch lmdb'."* ]]
  run bash -c 'source "$1"; set +e; validate_env_value DB_ENGINE "\"badger\""; echo "rc=$? warn=[$VALIDATION_WARNING]"' _ "$SB/haven"
  [ "$output" = "rc=0 warn=[]" ]
  # the editor's save path shows it (outside the TUI: on the terminal)
  run bash -c 'source "$1"; set +e; env_change_warning DB_ENGINE lmdb' _ "$SB/haven"
  [[ "$output" == *"WARN db/ holds badger data"* ]]
  rm -rf "$SB/db/"*
  run bash -c 'source "$1"; set +e; validate_env_value DB_ENGINE lmdb; echo "rc=$? warn=[$VALIDATION_WARNING]"' _ "$SB/haven"
  [ "$output" = "rc=0 warn=[]" ]
}

# 16
@test "16 help lists db-switch" {
  run hv help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n  db-switch <badger|lmdb>'* ]]
  [[ "$output" == *$'\n  db-switch --rollback'* ]]
}

# ---------- carried over from the P2 audit ----------

@test "signal handler stops a listed one-shot container although its compose client is gone, then restarts the relay" {
  printf 'havensw-relay-oneshot\n' > "$MOCK_DOCKER_STATE_DIR/running"
  run bash -c '
    source "$1"
    DOCKER_COMPOSE=(docker compose)
    ONESHOT_GUARD_FILE="$2" ONESHOT_GUARD_WHAT=backup ONESHOT_RELAY_WAS_RUNNING=1 ONESHOT_PID=""
    oneshot_on_signal TERM
  ' _ "$SB/haven" "$SB/docker-compose.yml"
  echo "rc=$status $output"; calls
  [ "$status" -eq 143 ]
  local o t
  o="$(line_of '^stop -t 10 havensw-relay-oneshot$')"
  t="$(line_of ' start relay$')"
  [ -n "$o" ] && [ -n "$t" ] && (( o < t ))
  relay_is_running
  ! grep -qxF havensw-relay-oneshot "$MOCK_DOCKER_STATE_DIR/running"
}

# ---------- beyond the list ----------

@test "--rollback refuses a marker it cannot trust (a path in a name field) and changes nothing" {
  fake_engine badger
  snapshot
  printf 'kind=switch\nsource=badger\ntarget=lmdb\nstarted=%s\nbackup=x.zip\nstash=../../etc\naside=\ndirs=private\nrelay_was_running=0\nenv_set=0\nenv_line=\nstep=moved\n' "$TS" > "$SB/db/.switch-in-progress"
  run hv db-switch --rollback
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid stash directory name"* ]]
  [ "$(result_line)" = "::result failed" ]
  [ -e "$SB/db/.switch-in-progress" ]
  [ -z "$(state_changes)" ]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  originals_in_place
}

@test "--rollback after an undo does not undo an older switch again" {
  fake_engine badger
  relay_running
  snapshot
  run hv db-switch lmdb --yes
  [ "$status" -eq 0 ]
  run hv db-switch --rollback --yes
  [ "$status" -eq 0 ]
  # an older stash left by hand next to the undo's set-aside directory
  mkdir -p "$SB/db/.pre-switch-badger-20260101-000000"
  cp -a "$SB/db/private" "$SB/db/.pre-switch-badger-20260101-000000/"
  db_files > "$TEST_DIR/mid.files"
  : > "$MOCK_DOCKER_STATE_DIR/calls.log"
  run hv db-switch --rollback --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to roll back"* ]]
  [ -z "$(state_changes)" ]
  db_files | cmp - "$TEST_DIR/mid.files"
}
