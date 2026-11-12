#!/usr/bin/env bats
# The guided data flows of the TUI (back up, restore, switch engine, undo an
# interrupted switch): what they offer, what they ask, which verb they run
# with which arguments, how the child runs (every key waits, Ctrl-C reaches
# the child), and that the flow code holds no docker logic of its own.
# The end-to-end runs against the real verbs and the docker mock are in
# tests/e2e-tui.sh.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sb"
  mkdir -p "$SB/db"
  printf 'DB_ENGINE="badger"\n' > "$SB/.env"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# in_haven <snippet> — ./haven sourced, ROOT_DIR the sandbox, actions stubbed:
# tui_flow_run records its arguments, dialogs answer from CONFIRM / TYPED
in_haven() {
  SNIP="$1" S="$SB" bash -c '
    export TERM=xterm-256color COLUMNS=80 LINES=24
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$S" BACKUP_DIR="$S/backups" DB_SWITCH_MARKER="$S/db/.switch-in-progress" SCRIPT_NAME=haven
    TUI_DOCKER_OK=0 LOG_LINES=()
    tui_update_layout
    tui_confirm() { echo "confirm[$1]"; [[ "${CONFIRM:-n}" == y ]]; }
    tui_message() { echo "message[$1|$2]"; }
    tui_prompt() { echo "prompt[$1]" >&2; printf "%s" "${TYPED:-}"; }
    tui_flow_run() { local IFS=" "; echo "run[${*:4}]"; TASK_RC=0; TASK_RESULT="${RESULT:-ok}"; TASK_STEP=${STEP:-7}; TASK_STEPS=([6]=restore [7]=start [1]=preflight); TASK_LINES=(); }
    tui_flow_finish() { echo "finish[$1|$2]"; }
    eval "$SNIP"
  ' 2>&1
}

badger() { local n; for n in private chat outbox inbox blossom; do mkdir -p "$SB/db/$n"; : > "$SB/db/$n/MANIFEST"; done; }

@test "flows: back up asks first; No runs nothing, Yes runs ./haven backup" {
  run in_haven 'tui_flow_backup; echo ---; CONFIRM=y tui_flow_backup'
  echo "$output"
  [[ "$output" == "confirm[Back up now? The relay is offline while the backup runs; the file goes to backups/ in this directory.]
---
confirm[Back up now? The relay is offline while the backup runs; the file goes to backups/ in this directory.]
run[backup]
finish[Backup finished|]" ]]
}

@test "flows: restore lists backups/ newest first with size and age; .partial and others left out" {
  mkdir -m 700 "$SB/backups"
  printf 'x%.0s' $(seq 2048) > "$SB/backups/b.zip"; touch -d '2 hours ago' "$SB/backups/b.zip"
  : > "$SB/backups/a.zip"; touch -d '3 days ago' "$SB/backups/a.zip"
  : > "$SB/backups/c.zip"; touch -d '5 minutes ago' "$SB/backups/c.zip"
  : > "$SB/backups/d.zip.partial-x"; : > "$SB/backups/notes.txt"
  run in_haven 'tui_flow_restore; echo "view=$TUI_VIEW"; tui_build_menu
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do echo "${MENU_IDS[$i]}|${MENU_VALUES[$i]}"; done'
  echo "$output"
  [[ "$output" == "view=restore_list
file:c.zip|0B 5m
file:b.zip|2.0K 2h
file:a.zip|0B 3d
back|" ]]
}

@test "flows: restore with no backups/ or an empty one names ./haven backup; an unreadable one is said" {
  run in_haven 'tui_flow_restore'
  [[ "$output" == "message[Restore a backup|There is no backup in backups/ yet. Make one with Back up now, or with ./haven backup in a terminal.]" ]]
  mkdir -m 700 "$SB/backups"
  run in_haven 'tui_flow_restore'
  [[ "$output" == *"There is no backup in backups/ yet."* ]]
  [ "$(id -u)" -ne 0 ] || skip "root reads any directory"
  chmod 000 "$SB/backups"
  run in_haven 'tui_flow_restore'
  chmod 700 "$SB/backups"
  [[ "$output" == "message[Restore a backup|backups/ cannot be read by "*"its permissions do not allow listing it.]" ]]
}

@test "flows: the chosen backup reaches the verb, --yes only after the TUI's own confirm" {
  run in_haven 'tui_flow_restore_pick "haven-backup-1.zip"; echo ---; CONFIRM=y tui_flow_restore_pick "haven-backup-1.zip"'
  echo "$output"
  [[ "$(sed -n 1p <<<"$output")" == "confirm[Restore haven-backup-1.zip? It adds the events of this backup that are missing; it never deletes or duplicates anything"* ]]
  [ "$(sed -n 2p <<<"$output")" = "---" ]
  [ "$(grep -c '^run\[' <<<"$output")" -eq 1 ]
  [ "$(grep '^run\[' <<<"$output")" = "run[restore haven-backup-1.zip --yes]" ]
}

@test "flows: switch overview from the disk; a wrong or empty typed name runs nothing, the right one runs the switch" {
  badger
  run in_haven 'tui_flow_switch; echo "view=$TUI_VIEW found=$FLOW_FOUND target=$FLOW_TARGET mixed=$FLOW_MIXED"; tui_build_menu
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do echo "${MENU_IDS[$i]}|${MENU_LABELS[$i]}"; done
    TYPED=badger tui_flow_switch_go; TYPED= tui_flow_switch_go; TYPED=LMDB tui_flow_switch_go
    TYPED=lmdb tui_flow_switch_go'
  echo "$output"
  [[ "$output" == *"view=switch found=badger target=lmdb mixed=0"* ]]
  [[ "$output" == *$'group:i1|On disk: badger\ngroup:i2|Target: lmdb'* ]]
  [[ "$output" == *$'switch|Switch to lmdb\nback|Back'* ]]
  [[ "$output" == *"message[Switch engine|Cancelled: you typed 'badger', not 'lmdb'. Nothing was changed.]"* ]]
  [[ "$output" == *"message[Switch engine|Cancelled; nothing was changed.]"* ]]
  [[ "$output" == *"message[Switch engine|Cancelled: you typed 'LMDB', not 'lmdb'. Nothing was changed.]"* ]]
  [ "$(grep -c '^run\[' <<<"$output")" -eq 1 ]
  [ "$(grep '^run\[' <<<"$output")" = "run[db-switch lmdb --yes]" ]
  [[ "$output" == *"finish[Engine switched|]"* ]]
}

@test "flows: mixed directories offer the two --from choices; the chosen one reaches the verb" {
  badger
  : > "$SB/db/private/data.mdb"
  printf 'DB_ENGINE="lmdb"\n' > "$SB/.env"
  run in_haven 'tui_flow_switch; tui_build_menu
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == from:* ]] && echo "${MENU_IDS[$i]}|${MENU_LABELS[$i]}"; done
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == from:badger ]] && TUI_SEL=$i; done
    tui_flow_details; printf "%s " "${DETAIL_LINES[@]}" | tr -s " "; echo
    TYPED=lmdb tui_handle_enter'
  echo "$output"
  [[ "$output" == *$'from:badger|From the badger side\nfrom:lmdb|From the lmdb side'* ]]
  [[ "$output" == *"Carries the notes of the badger side over into a clean lmdb database; the notes of the lmdb side stay in the set-aside directory db/.pre-switch-mixed-<time>/"* ]]
  [ "$(grep '^run\[' <<<"$output")" = "run[db-switch lmdb --from badger --yes]" ]
}

@test "flows: the result box names the failed step and the old engine; a refusal is the verb's own" {
  badger
  run in_haven 'tui_flow_switch_facts; RESULT=rolled-back STEP=6 TYPED=lmdb tui_flow_switch_go
    RESULT=failed STEP=1 TYPED=lmdb tui_flow_switch_go
    : > "$DB_SWITCH_MARKER"; RESULT=failed STEP=7 TYPED=lmdb tui_flow_switch_go'
  echo "$output"
  [[ "$output" == *"finish[Switch rolled back|Step 'restore' failed; the switch was rolled back: db/ and DB_ENGINE are back on badger.]"* ]]
  [[ "$output" == *"finish[Switch not started|]"* ]]
  [[ "$output" == *"finish[Switch failed|Step 'start' failed and the switch is not finished. Next step: ./haven db-switch --rollback"* ]]
}

@test "flows: with a switch marker the Data group leads with the undo; it asks, then runs --rollback" {
  run in_haven 'TUI_VIEW=main; tui_build_menu; echo "${MENU_IDS[6]}"'
  [ "$output" = "backup" ]
  : > "$SB/db/.switch-in-progress"
  run in_haven 'TUI_VIEW=main; tui_build_menu; echo "${MENU_IDS[5]} ${MENU_IDS[6]}|${MENU_KEYS[6]}|${MENU_LABELS[6]}"
    RESULT=rolled-back; TUI_SEL=1; tui_handle_key n; echo ---; CONFIRM=y RESULT=rolled-back tui_handle_key n'
  echo "$output"
  [[ "$(sed -n 1p <<<"$output")" == "group:data switch_rollback|n|Undo interrupted switch" ]]
  [[ "$(sed -n 2p <<<"$output")" == "confirm[Undo the interrupted switch?"* ]]
  [ "$(grep -c '^run\[' <<<"$output")" -eq 1 ]
  [ "$(grep '^run\[' <<<"$output")" = "run[db-switch --rollback]" ]
  [[ "$output" == *"finish[Switch undone|]"* ]]
}

@test "flows: the step list comes from the verb's ::step lines (no names of its own)" {
  run in_haven '
    for l in "::step 1/5 alpha" "INFO one" "::step 2/5 beta-step" "::step 3/5 gamma"; do tui_flow_take "$l"; done
    TASK_KIND=switch TASK_HEAD="Switching to lmdb" TUI_TASK_ACTIVE=1; printf -v TASK_T0 "%(%s)T" -1
    tui_render_left_task | python3 -I '"$REPO_ROOT"'/tests/term-emu.py 80 24 dump | sed -n "4,10p" | sed -E "s/^  //; s/ *$//"'
  echo "$output"
  [[ "$output" == "Switching to lmdb
Step 3 of 5 · 0m 0"?"s
───────────────────────────
✓ alpha
✓ beta-step
▸ gamma
  2 steps to go" ]]
}

@test "flows: the result box shows the verb's closing lines (after the last progress line)" {
  run in_haven '
    for l in "::step 6/7 restore" "INFO Restoring into a new lmdb database..." "WARN The engine switch failed: the restore exited with status 1." "INFO Rolled back: the badger directories are in db/ again." "INFO The relay is running (badger)." "::result rolled-back"; do tui_flow_take "$l"; done
    tui_flow_summary; echo "$_SUMMARY"'
  [[ "$output" == "WARN The engine switch failed: the restore exited with status 1.
Rolled back: the badger directories are in db/ again.
The relay is running (badger)." ]]
}

# a fake ./haven for tui_flow_run: prints steps, holds until $SB/release, then
# a last line; on SIGINT it says so and exits 130
fake_child() {
  cat > "$SB/haven" <<'SH'
#!/usr/bin/env bash
trap 'echo "child got INT"; exit 130' INT
echo "::step 1/2 first"
echo "args: $*"
while [[ ! -e "$(dirname "$0")/release" ]]; do sleep 0.05; done
echo "::step 2/2 second"
echo "last line"
echo "::result ok"
SH
  chmod +x "$SB/haven"
}

@test "flows: while the child runs Esc and q wait; the run ends only when the child ends" {
  fake_child
  ( sleep 2; : > "$SB/release" ) &
  run bash -c '
    export TERM=xterm-256color COLUMNS=80 LINES=24
    source '"$REPO_ROOT"'/haven; set +e
    ROOT_DIR='"$SB"' SCRIPT_NAME=haven FOLLOW_LOGS=0; tui_update_layout
    tui_flow_run backup "Back up now" "Backing up…" backup >/dev/null
    (IFS=" "; echo "rc=$TASK_RC result=$TASK_RESULT steps=${TASK_STEPS[*]}"); printf "%s\n" "${TASK_LINES[@]}"' \
    < <(printf 'q'; sleep 0.4; printf '\033'; sleep 0.4; printf 'q\033q'; sleep 4)
  wait
  echo "$output"
  [[ "$output" == "rc=0 result=ok steps=first second
::step 1/2 first
args: backup
::step 2/2 second
last line
::result ok" ]]
}

@test "flows: Ctrl-C (SIGINT to the TUI) reaches the child, the TUI reports and goes on" {
  fake_child
  run bash -c '
    export TERM=xterm-256color COLUMNS=80 LINES=24
    source '"$REPO_ROOT"'/haven; set +e
    ROOT_DIR='"$SB"' SCRIPT_NAME=haven FOLLOW_LOGS=0; tui_update_layout
    trap "echo TUI-would-quit" INT
    ( sleep 1.5; kill -INT $$ ) &
    tui_flow_run backup "Back up now" "Backing up…" backup >/dev/null </dev/null
    echo "rc=$TASK_RC int=$TASK_INT"; printf "%s\n" "${TASK_LINES[@]}"
    trap -p INT'
  echo "$output"
  [[ "$output" == "rc=130 int=1
::step 1/2 first
args: backup
child got INT
trap -- 'echo TUI-would-quit' SIGINT" ]]
}

# flow_bodies <file> — the bodies of the flow functions: every function whose
# name starts with tui_flow_, plus tui_render_left_task and
# tui_render_right_task, from its "name() {" line to the next "}" in column 1;
# comment lines left out
flow_bodies() {
  awk '
    /^(tui_flow_[a-z_]*|tui_render_left_task|tui_render_right_task)\(\) \{/ { on = 1; print FNR ": " $0; next }
    on && /^\}/ { on = 0; next }
    on && !/^[ \t]*#/ { print FNR ": " $0 }
  ' "$1"
}

@test "flows: the flow code calls no docker, compose or dc (the verbs do)" {
  local bodies hits
  bodies="$(flow_bodies "$REPO_ROOT/haven")"
  [ "$(grep -c '() {' <<<"$bodies")" -ge 15 ]
  hits="$(grep -E '(^|[^a-z_])(docker|compose)([^a-z_]|$)|(^|[ ;(|&])dc ' <<<"$bodies" | grep -v '() {' || true)"
  echo "hits: $hits"
  [ -z "$hits" ]
  # control: a docker call planted in a flow function of a copy is found
  sed 's|^tui_flow_backup() {$|&\n  docker compose stop relay|' "$REPO_ROOT/haven" > "$TEST_DIR/haven"
  hits="$(flow_bodies "$TEST_DIR/haven" | grep -E '(^|[^a-z_])(docker|compose)([^a-z_]|$)|(^|[ ;(|&])dc ' | grep -v '() {' || true)"
  [[ "$hits" == *"docker compose stop relay"* ]]
}
