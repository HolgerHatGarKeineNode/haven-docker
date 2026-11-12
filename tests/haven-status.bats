#!/usr/bin/env bats
# The status view (Tab from the main view): one "label  value" field per line,
# in a fixed order, a word for every state; the engine is the one on disk,
# with .env's disagreement said in the same line. Docker answers from the
# scripted mock; ROOT_DIR is a sandbox.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EMU="$REPO_ROOT/tests/term-emu.py"

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sb"
  mkdir -p "$SB/db" "$SB/blossom" "$TEST_DIR/state"
  cp "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/docker-compose.tor.yml" "$SB/"
  printf 'RELAY_URL="relay.example.org"\nDB_ENGINE="badger"\n' > "$SB/.env"
  printf 'haven-relay\n' > "$TEST_DIR/state/running"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && chmod -R u+rwX "$TEST_DIR" 2>/dev/null
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# fields — the collected fields, "label|value[|style]" per line
fields() {
  PATH="$REPO_ROOT/tests/mock:$PATH" MOCK_DOCKER_STATE_DIR="$TEST_DIR/state" S="$SB" bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    detect_compose
    ROOT_DIR="$S" BACKUP_DIR="$S/backups" COMPOSE_FILE_PLAIN="$S/docker-compose.yml" COMPOSE_FILE_TOR="$S/docker-compose.tor.yml"
    tui_collect_status
    printf "%s\n" "${TUI_STATUS_CACHE[@]}"'
}

badger() { local n; for n in private chat outbox inbox blossom; do mkdir -p "$SB/db/$n"; : > "$SB/db/$n/MANIFEST"; done; }

@test "status: the fields in the specified order, each a word for its state" {
  badger
  run fields
  [ "$status" -eq 0 ]
  echo "$output"
  [ "$(cut -d'|' -f1 <<<"$output" | tr '\n' ' ')" = "Relay Mode URL Database Media Last backup Image Container " ]
  [[ "$output" == *"Relay|● Running, up 2 hours"* ]]
  [[ "$output" == *"Mode|Docker"* ]]
  [[ "$output" == *"URL|wss://relay.example.org"* ]]
  [[ "$output" == *"Database|badger, db/ "* ]]
  [[ "$output" == *"Media|blossom/ "* ]]
  [[ "$output" == *"Image|"*", sha256:abcdef123456"* ]]
  [[ "$output" == *"Container|haven-relay: running, up 2 hours"* ]]
}

@test "status: without a backup the line says never, in the warn style" {
  run fields
  [[ "$output" == *$'\nLast backup|never|warn\n'* ]]
}

@test "status: the newest backup with its age; an unreadable backups/ is said" {
  mkdir -m 700 "$SB/backups"
  : > "$SB/backups/haven-backup-old.zip"
  : > "$SB/backups/haven-backup-new.zip"
  : > "$SB/backups/haven-backup-x.zip.partial-abc"
  touch -d '3 days ago' "$SB/backups/haven-backup-old.zip"
  touch -d '2 hours ago' "$SB/backups/haven-backup-new.zip"
  run fields
  [[ "$output" == *$'\nLast backup|haven-backup-new.zip, 2 h ago\n'* ]]
  [ "$(id -u)" -ne 0 ] || skip "root reads any directory"
  chmod 000 "$SB/backups"
  run fields
  [[ "$output" == *$'\nLast backup|backups/ cannot be read|warn\n'* ]]
}

@test "status: files of both engines and an .env naming the other engine are said in plain words" {
  badger
  : > "$SB/db/private/data.mdb"
  run fields
  [[ "$output" == *"Database|files of both engines in db/ (private), db/ "* ]]
  rm "$SB/db/private/data.mdb"
  printf 'DB_ENGINE="lmdb"\n' > "$SB/.env"
  run fields
  [[ "$output" == *"Database|badger on disk, but .env names lmdb, db/ "* ]]
  rm -rf "$SB/db/"*
  run fields
  [[ "$output" == *"Database|no data yet (.env: lmdb), db/ "* ]]
}

@test "status: with Docker offline the relay state says so and the other fields stay" {
  run env PATH="$TEST_DIR/nodocker:$PATH" S="$SB" bash -c '
    mkdir -p "'"$TEST_DIR"'/nodocker"; printf "#!/bin/sh\nexit 1\n" > "'"$TEST_DIR"'/nodocker/docker"; chmod +x "'"$TEST_DIR"'/nodocker/docker"
    source '"$REPO_ROOT"'/haven; set +e
    ROOT_DIR="$S" BACKUP_DIR="$S/backups"; tui_collect_status; printf "%s\n" "${TUI_STATUS_CACHE[@]}"'
  echo "$output"
  [[ "$output" == "Relay|○ Unknown: Docker is offline"* ]]
  [[ "$output" == *"Last backup|never|warn"* ]]
  [[ "$output" == *"Container|unknown: Docker is offline" ]]
}

@test "status: drawn in the right pane, labels in order, frame intact (80x24)" {
  badger
  local screen
  screen="$(PATH="$REPO_ROOT/tests/mock:$PATH" MOCK_DOCKER_STATE_DIR="$TEST_DIR/state" S="$SB" bash -c '
    export TERM=xterm-256color COLUMNS=80 LINES=24
    source '"$REPO_ROOT"'/haven; set +e; detect_compose
    ROOT_DIR="$S" BACKUP_DIR="$S/backups" COMPOSE_FILE_PLAIN="$S/docker-compose.yml" COMPOSE_FILE_TOR="$S/docker-compose.tor.yml"
    TUI_DOCKER_OK=1 LOG_LINES=(); tui_update_layout; TUI_VIEW=main; TUI_RIGHT_MODE=status
    tui_draw_frame 0; tui_render_left_menu; tui_render_right_panel')"
  printf '%s' "$screen" | python3 -I "$EMU" 80 24 dump | sed -n '4,11p' | sed -E 's/^.*│ ([A-Za-z]+( backup)?) .*/\1/' > "$TEST_DIR/labels"
  cat "$TEST_DIR/labels"
  [ "$(tr '\n' ' ' < "$TEST_DIR/labels")" = "Relay Mode URL Database Media Last backup Image Container " ]
  printf '%s' "$screen" | python3 -I "$EMU" 80 24 frame | grep -qx 'overflow 0'
}
