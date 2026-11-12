#!/usr/bin/env bats
# The P6 security audit, unit level (F1-F5): .env values are written byte for
# byte and never become extra lines; a write that comes out wrong is put back;
# the settings editor shows the value Compose uses and says when a key is in
# .env more than once; crafted backup names never reach the restore list;
# info/warn/success/die print foreign text with %s; the flow's intake strips
# every escape and control; the masking rule by name and by value; the edit
# prompt never receives the current value; cleanup survives a piped stdin.
# The terminal-level checks (bracketed paste, capture-pane, Ctrl-C windows)
# are in tests/e2e-tui.sh, sections 22-26.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sb"
  mkdir -p "$SB/db"
  cp "$REPO_ROOT/.env.example" "$SB/.env.example"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# in_haven <snippet> — ./haven sourced, ROOT_DIR = the sandbox, docker offline
in_haven() {
  SNIP="$1" S="$SB" bash -c '
    export TERM=xterm-256color COLUMNS="${COLS:-120}" LINES="${ROWS:-30}"
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$S" BACKUP_DIR="$S/backups" SCRIPT_NAME=haven
    TUI_DOCKER_OK=0 LOG_LINES=()
    docker() { return 1; }
    tui_update_layout
    eval "$SNIP"
  '
}

# --- F1: values are one line, byte for byte ---------------------------------

@test "F1: typed backslash text is stored byte for byte on one line (a\\nb, C:\\path, \\033]2;x\\007)" {
  printf 'A=1\nPRIVATE_RELAY_NAME="x"\n' > "$SB/.env"
  run in_haven '
    for v in "a\\nb" "C:\\path" "\\033]2;x\\007"; do
      validate_env_value PRIVATE_RELAY_NAME "$v" || { echo "refused [$v] $VALIDATION_ERROR"; continue; }
      set_env_var PRIVATE_RELAY_NAME "$VALIDATION_VALUE" >/dev/null; echo "rc=$?"
      grep -c "" "$S/.env"; grep "^PRIVATE_RELAY_NAME=" "$S/.env"
    done'
  echo "$output"
  [[ "$output" == 'rc=0
2
PRIVATE_RELAY_NAME=a\nb
rc=0
2
PRIVATE_RELAY_NAME=C:\path
rc=0
2
PRIVATE_RELAY_NAME=\033]2;x\007' ]]
  ! LC_ALL=C grep -q $'\x1b' "$SB/.env"
}

@test "F1: raw CR, LF, ESC and TAB are refused by validate_env_value and set_env_var; .env stays byte-identical" {
  printf 'A=1\nOWNER_NPUB=orig\n' > "$SB/.env"
  cp "$SB/.env" "$TEST_DIR/before"
  run in_haven '
    for v in $'"'"'a\rb'"'"' $'"'"'a\nOWNER_NPUB=x'"'"' $'"'"'a\e]2;T\ab'"'"' $'"'"'a\tb'"'"'; do
      for k in PRIVATE_RELAY_NAME UNRULED_KEY OWNER_NPUB; do
        validate_env_value "$k" "$v" && echo "ACCEPTED by validate: $k"
        set_env_var "$k" "$v" >/dev/null && echo "WRITTEN by set_env_var: $k"
      done
    done; echo end'
  echo "$output"
  [ "$output" = end ]
  cmp "$SB/.env" "$TEST_DIR/before"
}

@test "F1: a value that is not one quoted string is refused (the pasted \"a\"\\nOWNER_NPUB=x\\nY=\"b\" typed as text)" {
  run in_haven '
    for v in "\"a\"\\nOWNER_NPUB=x\\nY=\"b\"" "\"x\"y\"" "'"'"'a'"'"'b'"'"'" "\"esc\\\""; do
      validate_env_value PRIVATE_RELAY_NAME "$v" && echo "ACCEPTED [$v]"
    done
    for v in "\"ok \\\" quote\"" "\"two words\"" "'"'"'single'"'"'" "plain"; do
      validate_env_value PRIVATE_RELAY_NAME "$v" || echo "REFUSED [$v] $VALIDATION_ERROR"
    done; echo end'
  echo "$output"
  [ "$output" = end ]
}

@test "F1: a write that comes out with an extra line is put back byte for byte and fails" {
  printf 'K=1\nA=2\n' > "$SB/.env"
  cp "$SB/.env" "$TEST_DIR/before"
  run in_haven '
    replace_file_from() { printf "K=x\nINJECTED=1\nA=2\n" > "$1"; }
    set_env_var K x; echo "rc=$?"'
  echo "$output"
  [[ "$output" == *"the file before the write was put back"* ]]
  [[ "$output" == *"rc=1" ]]
  cmp "$SB/.env" "$TEST_DIR/before"
  [ -z "$(find "$SB" -maxdepth 1 -name '.env.pre.*')" ]
  # remove: a writer that keeps the key is put back too
  run in_haven '
    replace_file_from() { printf "K=1\nA=2\nB=3\n" > "$1"; }
    remove_env_var K; echo "rc=$?"'
  [[ "$output" == *"rc=1" ]]
  cmp "$SB/.env" "$TEST_DIR/before"
}

@test "F1: a key in .env twice: list row and details show the last value and say so; Edit writes the last line" {
  printf 'RELAY_URL="first.example"\nOWNER_NPUB=npub1first\nRELAY_URL="last.example"\n' > "$SB/.env"
  run in_haven '
    tui_set_view env_list; tui_build_menu; TUI_NEED_MENU=0
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:RELAY_URL ]] && { echo "row=${MENU_VALUES[$i]}"; TUI_SEL=$i; }; done
    tui_setting_details; printf "%s " "${DETAIL_LINES[@]}" | tr -s " "; echo'
  echo "$output"
  [[ "$output" == *"row=(2×) last.example"* ]]
  [[ "$output" == *"last.example"* ]]
  [[ "$output" != *"first.example"* ]]
  [[ "$output" == *"RELAY_URL is in .env 2 times; Compose uses the last line, shown here, and Edit changes that line only."* ]]
  run in_haven 'set_env_var RELAY_URL "\"new.example\"" && cat "$S/.env"'
  [[ "$output" == 'RELAY_URL="first.example"
OWNER_NPUB=npub1first
RELAY_URL="new.example"' ]]
}

# --- F2: crafted names, escape-safe messages, the flow intake ---------------

@test "F2: the restore list shows only names the verb accepts, regular files, no symlinks" {
  mkdir -m 700 "$SB/backups"
  : > "$SB/backups/good-1.zip"
  : > "$SB/backups/-x.zip"
  : > "$SB/backups/with space.zip"
  : > "$SB/backups/"'t\033]2;T\007.zip'
  : > "$SB/backups/"$'e\x1b]2;T\x07.zip'
  ln -s good-1.zip "$SB/backups/link.zip"
  mkdir "$SB/backups/dir.zip"
  run in_haven 'tui_flow_backups_list; printf "[%s]\n" "${FLOW_FILES[@]}"'
  echo "$output"
  [ "$output" = "[good-1.zip]" ]
}

@test "F2: info, warn, success and die print foreign text with %s: no ESC byte, no extra line" {
  local f='a\033[2Jb\nc\a'
  run in_haven 'info "'"$f"'"; warn "'"$f"'"; success "'"$f"'"; info_plain "'"$f"'"; ( CLR_RED="\033[31m" CLR_RESET="\033[0m"; die "'"$f"'" ) 2>&1'
  echo "$output"
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" == 'INFO a\033[2Jb\nc\a' ]]
  [[ "${lines[1]}" == 'WARN a\033[2Jb\nc\a' ]]
  [[ "${lines[2]}" == 'OK a\033[2Jb\nc\a' ]]
  # die keeps its own colour (the script's constant), not the text's
  [[ "${lines[4]}" == $'\e[31mERROR\e[0m a\\033[2Jb\\nc\\a' ]]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -cd '\033' | wc -c)" -eq 2 ]
}

@test "F2: the flow intake strips OSC 52, C1 CSI and every control; a forged ::result mid-line does not count" {
  run in_haven '
    TASK_LINES=() TASK_RESULT="" TASK_STEPS=() TASK_STEP=0 TASK_STEP_TOTAL=0
    tui_flow_take "::result failed"
    tui_flow_take $'"'"'name \e]52;c;SGVsbG8=\a end'"'"'
    tui_flow_take $'"'"'csi \x9b31m8bit \xc2\x9b31mc1 \e[2Jtext'"'"'
    tui_flow_take $'"'"'file   ::result ok'"'"'
    tui_flow_take $'"'"'\e[G::result ok'"'"'
    printf "%s\n" "${TASK_LINES[@]}"; echo "result=$TASK_RESULT"'
  echo "$output"
  [[ "$output" == '::result failed
name  end
csi 31m8bit 31mc1 text
file   ::result ok
::result ok
result=failed' ]]
  [ "$(printf '%s' "$output" | LC_ALL=C tr -cd '\000-\011\013-\037\177\200-\237' | wc -c)" -eq 0 ]
}

@test "F2: the result box takes the relay sentence only from a line that starts with it" {
  run in_haven '
    TASK_LINES=("Restoring backups/x-The relay is running (lmdb).zip" "Stopping the relay — the database allows a single writer." "The relay was not running before and was not started.")
    tui_flow_relay_note; echo "$_RELAY_NOTE"'
  echo "$output"
  [ "$output" = "The relay was not running and stays stopped." ]
}

# --- F3: the masking rule ----------------------------------------------------

@test "F3: masked by name and by value; npubs, URLs, icons, file paths and the 24 limiter counts stay visible" {
  local masked_names="S3_SECRETKEY APITOKEN AUTHTOKEN PRIVKEY PRIVATEKEY SECRETKEY ACCESSKEY RELAY_PRIVKEY SECKEY NOSTR_SECKEY TS_AUTHKEY NGROK_AUTHTOKEN KEYS PASSWORDS SEED MNEMONIC XPRV SK NOSTR_SK MACAROON RUNE BUNKER_URL NWC_URL DB_PW DB_PWD DSN apiKey dbPassword nostrSk walletSeed S3_SECRET_KEY S3_ACCESS_KEY_ID API_TOKEN DB_PASSWORD NSEC CREDENTIALS AUTH AUTHORIZATION"
  local limiters
  limiters="$(grep -oE '^[A-Z_]+_(TOKENS_PER_INTERVAL|LIMITER_INTERVAL|MAX_TOKENS)=' "$REPO_ROOT/.env.example" | tr -d = | tr '\n' ' ')"
  [ "$(wc -w <<<"$limiters")" -eq 24 ]
  run in_haven '
    for k in '"$masked_names"'; do env_key_is_sensitive "$k" "plain" || echo "NOT MASKED (name): $k"; done
    # by value, whatever the key (NIP46_URI and DATABASE_URL are masked through their values)
    while IFS="|" read -r k v; do env_key_is_sensitive "$k" "$v" || echo "NOT MASKED (value): $k=$v"; done <<EOF
NIP46_URI|bunker://ab12?relay=wss://r.example&secret=s3cr3t
WALLET|nostr+walletconnect://ab12?relay=wss://r.example&secret=s3cr3t
DATABASE_URL|postgres://user:pass@db.example/haven
X|"postgres://user:pass@db.example/haven"
X|nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
X|ncryptsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqq
X|0123456789abcdef0123456789abcdef0123456789abcdef0123456789ABCDEF
EOF
    for k in OWNER_NPUB PRIVATE_RELAY_NPUB CHAT_RELAY_NPUB RELAY_URL PRIVATE_RELAY_ICON IMPORT_SEED_RELAYS_FILE BLASTR_RELAYS_FILE WHITELISTED_NPUBS_FILE BLOSSOM_PATH WOT_DEPTH NIP46_URI DATABASE_URL '"$limiters"'; do
      env_key_is_sensitive "$k" "visible-value" && echo "MASKED (name): $k"
    done
    for v in npub1abc wss://relay.example https://example.org/icon.png relays_import.json 1000 0123456789abcdef https://user@host.example/; do
      env_key_is_sensitive SOME_SETTING "$v" && echo "MASKED (value): $v"
    done; echo end'
  echo "$output"
  [ "$output" = end ]
}

@test "F3: canaries in fused names and value forms never appear in the list, the details pane or the status view" {
  local c1=CANARYa1fused c2=CANARYb2fused c3=CANARYc3fused
  cp "$REPO_ROOT/.env.example" "$SB/.env"
  {
    printf 'S3_SECRETKEY=%s\nNGROK_AUTHTOKEN=%s\nnostrSk=%s\n' "x$c1" "x$c2" "x$c3"
    printf 'MY_BUNKER_LINK="bunker://ab?relay=wss://r&secret=CANARYv1secret"\n'
    printf 'MY_DB=postgres://user:CANARYv2pass@db.example/x\n'
    printf 'MY_KEYHEX=CA0A0F0000000000000000000000000000000000000000000000000000c0ffee\n'
  } >> "$SB/.env"
  mkdir -p "$TEST_DIR/state"
  echo haven-relay > "$TEST_DIR/state/running"
  run env PATH="$REPO_ROOT/tests/mock:$PATH" MOCK_DOCKER_STATE_DIR="$TEST_DIR/state" bash -c '
    export TERM=xterm-256color COLUMNS=120 LINES=30
    source '"$REPO_ROOT"'/haven; set +e
    ROOT_DIR='"$SB"' BACKUP_DIR='"$SB"'/backups SCRIPT_NAME=haven LOG_LINES=()
    tui_update_layout
    tui_set_view env_list; tui_build_menu; TUI_NEED_MENU=0
    printf "%s\n" "${MENU_LABELS[@]}" "${MENU_VALUES[@]}"
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do
      [[ "${MENU_IDS[$i]}" == key:* ]] || continue
      TUI_SEL=$i; tui_setting_details; printf "%s\n" "${DETAIL_LINES[@]}"
    done
    TUI_STATUS_TS=""; tui_render_right_status
    printf "%s\n" "${TUI_STATUS_CACHE[@]}"' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3_SECRETKEY"* && "$output" == *"Database|"* ]]
  local c
  for c in "$c1" "$c2" "$c3" CANARYv1secret CANARYv2pass c0ffee; do
    [[ "$output" != *"$c"* ]] || { echo "LEAK: $c"; false; }
  done
}

# --- F5: the edit prompt never receives the current value -------------------

@test "F5: Edit hands the prompt no default; an empty Enter writes nothing and validates nothing" {
  printf 'S3_SECRET_KEY=my secret value\n' > "$SB/.env"
  cp "$SB/.env" "$TEST_DIR/before"
  run in_haven '
    TUI_ACTIVE=1 TUI_VIEW=env_item MENU_IDS=(edit) TUI_SEL=0 CURRENT_ENV_KEY=S3_SECRET_KEY
    tui_prompt() { echo "prompt-default=[$2]" >&2; printf ""; }
    restart_after_env_change() { echo "RESTART"; }
    tui_handle_enter'
  echo "$output"
  [ "$output" = "prompt-default=[]" ]
  cmp "$SB/.env" "$TEST_DIR/before"
}

# --- F4: cleanup with stdin from a pipe ---------------------------------------

@test "F4: tui_cleanup with stdin from a pipe finishes under errexit (rmcup written, state reset)" {
  run bash -c '
    export TERM=xterm-256color
    source '"$REPO_ROOT"'/haven
    # restoring the modes the terminal already has (or "sane" without one)
    TUI_ACTIVE=1 TUI_STTY_ORIG="$(stty -g </dev/tty 2>/dev/null || echo sane)" TUI_PASTE_ENABLED=0 LOG_PID=""
    echo x | { tui_cleanup; echo "active=$TUI_ACTIVE"; }' 2>/dev/null
  echo "$output" | od -c | head -5
  [[ "$output" == *"active=0"* ]]
  [[ "$output" == *$'\e[?1049l'* ]]
}

# --- restart after a saved setting -------------------------------------------

@test "restart after a saved setting runs captured: nothing of docker's output on the terminal, the result in a box" {
  printf 'RELAY_URL="r.example"\nDOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" > "$SB/.env"
  for f in relays_import relays_blastr blacklisted_npubs whitelisted_npubs; do printf '[]\n' > "$SB/$f.json"; done
  cp "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/docker-compose.tor.yml" "$SB/"
  mkdir -p "$TEST_DIR/state" "$SB/blossom"
  echo haven-relay > "$TEST_DIR/state/running"
  run env PATH="$REPO_ROOT/tests/mock:$PATH" MOCK_DOCKER_STATE_DIR="$TEST_DIR/state" bash -c '
    export TERM=xterm-256color COLUMNS=120 LINES=30
    source '"$REPO_ROOT"'/haven; set +e
    ROOT_DIR='"$SB"' SCRIPT_NAME=haven LOG_LINES=() DOCKER_COMPOSE=(docker compose)
    TUI_ACTIVE=1 FOLLOW_LOGS=0
    tui_message() { printf "BOX[%s] %s\n" "$1" "$2"; }
    restart_after_env_change' 2>&1
  echo "$output"
  [[ "$output" == "BOX[Restart] .env was saved and the relay restarted (Plain) to apply it."* ]]
  [[ "$output" != *"Up "* && "$output" != *"Starting services"* ]]
  grep -qE '^compose .* up -d' "$TEST_DIR/state/calls.log"
}

# --- P6 final rework (D1-D5, P1-P5, B1, B3) -----------------------------------
# The terminal-level halves (the restart box against the scripted mock, Ctrl-C
# during the box layout, die in a captured action, OSC in the log pane, the
# terminal modes after q / Ctrl-C / SIGTERM) are tests/e2e-tui.sh, 26-30.

# in_mock <snippet> — like in_haven, but with the scripted docker mock first on
# PATH (state in $TEST_DIR/state); refuses to run when docker is not the mock
in_mock() {
  mkdir -p "$TEST_DIR/state"
  SNIP="$1" S="$SB" MOCK="$REPO_ROOT/tests/mock" PATH="$REPO_ROOT/tests/mock:$PATH" MOCK_DOCKER_STATE_DIR="$TEST_DIR/state" bash -c '
    [ "$(command -v docker)" = "$MOCK/docker" ] || { echo "REFUSED: docker is $(command -v docker), not the mock"; exit 99; }
    export TERM=xterm-256color COLUMNS=120 LINES=30
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$S" BACKUP_DIR="$S/backups" SCRIPT_NAME=haven LOG_LINES=() DOCKER_COMPOSE=(docker compose)
    COMPOSE_FILE_PLAIN="$S/docker-compose.yml" COMPOSE_FILE_TOR="$S/docker-compose.tor.yml"
    TUI_ACTIVE=1 FOLLOW_LOGS=0
    tui_update_layout
    tui_message() { printf "BOX[%s] %s\n" "$1" "$2"; }
    eval "$SNIP"
  '
}
mock_sandbox() { # compose files, JSON lists, data dirs, a running relay
  printf 'RELAY_URL="r.example"\nDOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" > "$SB/.env"
  for f in relays_import relays_blastr blacklisted_npubs whitelisted_npubs; do printf '[]\n' > "$SB/$f.json"; done
  cp "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/docker-compose.tor.yml" "$SB/"
  mkdir -p "$TEST_DIR/state" "$SB/blossom"
  echo haven-relay > "$TEST_DIR/state/running"
}

@test "D1: a failing 'up' is returned by start_services and restart_services under run_capture (errexit off)" {
  mock_sandbox
  run in_mock 'MOCK_START_FAILS=1 run_capture restart_services plain; echo "status=$RUN_STATUS"; printf "%s\n" "$RUN_OUTPUT" | grep -c "relay was not started"
    export MOCK_START_FAILS=1; run_capture start_services plain; echo "status=$RUN_STATUS"'
  echo "$output"
  [[ "${lines[0]}" == "status=1" ]]
  [[ "${lines[1]}" == "1" ]]
  [[ "${lines[2]}" == "status=1" ]]
}

@test "D1: the restart box is built from the relay state after the restart: a failed start says NOT running, never 'restarted'" {
  mock_sandbox
  run in_mock 'export MOCK_START_FAILS=1; tui_env_save PRIVATE_RELAY_NAME "\"New name\""'
  echo "$output"
  [[ "$output" == "BOX[Restart] .env was saved; the restart to apply it failed (exit 1). The relay is NOT running: start it with s in the main view."* ]]
  [[ "$output" != *"restarted"* ]]
  [ ! -s "$TEST_DIR/state/running" ]
  grep -qx 'PRIVATE_RELAY_NAME="New name"' "$SB/.env"
}

@test "D1: a refused write (read-only directory) is shown in a box, nothing is restarted, .env unchanged" {
  [ "$(id -u)" -ne 0 ] || skip "root writes into a read-only directory"
  mock_sandbox
  cp "$SB/.env" "$TEST_DIR/before"
  chmod 555 "$SB"
  run in_mock 'restart_after_env_change() { echo RESTART-CALLED; }; tui_env_save PRIVATE_RELAY_NAME "\"New name\""; echo "rc=$?"'
  chmod 755 "$SB"
  echo "$output"
  [[ "$output" == "BOX[PRIVATE_RELAY_NAME] .env was not changed, and the relay was not restarted."$'\n'"cannot create a temporary file next to .env; it was not changed"* ]]
  [[ "$output" != *RESTART-CALLED* && "$output" != *saved* && "$output" != *"WARN "* ]]
  [[ "$output" == *"rc=0" ]]
  cmp "$SB/.env" "$TEST_DIR/before"
}

@test "D1: a writer that returns non-zero stops the restart; set and remove alike" {
  mock_sandbox
  run in_mock '
    restart_after_env_change() { echo RESTART-CALLED; }
    set_env_var() { warn "set refused for $1"; return 1; }
    remove_env_var() { warn "remove refused for $1"; return 1; }
    tui_env_save RELAY_URL x; tui_env_save RELAY_URL --remove'
  echo "$output"
  [ "${lines[0]}" = "BOX[RELAY_URL] .env was not changed, and the relay was not restarted." ]
  [ "${lines[1]}" = "set refused for RELAY_URL" ]
  [ "${lines[2]}" = "BOX[RELAY_URL] .env was not changed, and the relay was not restarted." ]
  [ "${lines[3]}" = "remove refused for RELAY_URL" ]
  [[ "$output" != *RESTART-CALLED* ]]
  [ ! -e "$TEST_DIR/state/calls.log" ] || ! grep -qE ' (up|down|stop|start) ' "$TEST_DIR/state/calls.log"
}

@test "D1: a saved setting with the relay stopped or docker away ends in a box too (no message over the frame)" {
  mock_sandbox
  : > "$TEST_DIR/state/running"
  run in_mock 'tui_env_save PRIVATE_RELAY_NAME x'
  echo "$output"
  [ "$output" = "BOX[Restart] .env was saved. The relay is not running, so nothing was restarted; the change applies when it starts (s in the main view)." ]
  run in_haven 'tui_message() { printf "BOX[%s] %s\n" "$1" "$2"; }; TUI_ACTIVE=1; tui_env_save PRIVATE_RELAY_NAME y'
  echo "$output"
  [ "$output" = "BOX[Restart] .env was saved. Docker is not reachable, so nothing was restarted; the change applies at the next start." ]
}

# Compose 5.7.0 (`docker compose version`), measured 2026-11-12 with
# `docker compose config --format json` on a scratch .env per row: "V=<raw>"
# then "W=after", the service reading ${V} and ${W}. The validator accepts a
# raw value exactly when Compose reads the file, W stays "after" (nothing of the
# next line is taken) and V is the whole typed text as one value (nothing
# after a closing quote dropped, no inline comment cut off). Columns: expected
# outcome, raw value, what Compose did. No docker is needed here.
@test "D2: env_value_quotes_ok / validate_env_value against what Compose 5.x parses (45 values)" {
  cat > "$TEST_DIR/table" <<'TABLE'
accept	plain	reads "plain"
accept	"double"	reads "double"
accept	'single'	reads "single"
accept	""	reads ""
accept	''	reads ""
accept	"a\"b"	reads "a\"b"
accept	"a'b"	reads "a'b"
accept	'a"b'	reads "a\"b"
accept	'a\'b'	reads "a'b"
accept	"a\\"	reads "a\\"
refuse	"a\"	refused
refuse	"a\\\"	refused
accept	'a\\'	reads "a\\\\"
refuse	'a\'	refused
refuse	'a\\\'	refused
accept	"a#b"	reads "a#b"
accept	'a#b'	reads "a#b"
refuse	"a" #c	reads "a"
refuse	"a"#c	reads "a"
refuse	'a' #c	reads "a"
refuse	'a'#c	reads "a"
accept	a"b	reads "a\"b"
accept	a'b	reads "a'b"
refuse	a #b	reads "a"
accept	a#b	reads "a#b"
refuse	"a"b	reads "a"
refuse	'a'b	reads "a"
refuse	"a	refused
refuse	'a	refused
accept	"a\nb"	reads "a\nb"
accept	'a\nb'	reads "a\\nb"
refuse	"a""b"	refused
refuse	"	refused
refuse	'	refused
refuse	'My relay\'	refused
accept	"a\\b"	reads "a\\b"
accept	'a\b'	reads "a\\b"
accept	"a\\\\"	reads "a\\\\"
accept	'a\\\\'	reads "a\\\\\\\\"
accept	"a\\\"b"	reads "a\\\"b"
refuse	'a\\'b'	refused
accept	"\\"	reads "\\"
accept	'\\'	reads "\\\\"
refuse	"\"	refused
refuse	'\'	refused
TABLE
  run in_haven '
    n=0
    while IFS=$'"'"'\t'"'"' read -r want raw reading; do
      if validate_env_value PRIVATE_RELAY_NAME "$raw"; then got=accept; else got=refuse; fi
      [ "$got" = "$want" ] || printf "MISMATCH %s: want %s, got %s (Compose %s)\n" "$raw" "$want" "$got" "$reading"
      n=$((n + 1))
    done < "'"$TEST_DIR"'/table"; echo "rows=$n"'
  echo "$output"
  [ "$output" = "rows=45" ]
}

@test "D3: tui_update_layout keeps the previous size when tput yields no number (a killed subshell prints nothing)" {
  run in_haven '
    TUI_COLS=133 TUI_LINES=41
    tput() { case "$1" in cols|lines) printf "";; *) command tput "$@";; esac; }
    tui_update_layout; echo "$TUI_COLS x $TUI_LINES too_small=$TUI_TOO_SMALL"
    tput() { echo garbage; }
    tui_update_layout; echo "$TUI_COLS x $TUI_LINES"
    printf -v x "%d" "$TUI_COLS" && echo "printf ok"'
  echo "$output"
  [ "${lines[0]}" = "133 x 41 too_small=0" ]
  [ "${lines[1]}" = "133 x 41" ]
  [ "${lines[2]}" = "printf ok" ]
}

@test "D4: .env.pre.* is git-ignored, like .env.tmp.*" {
  run git -C "$REPO_ROOT" check-ignore -v .env.pre.Ab12Cd .env.tmp.Ab12Cd
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == ".gitignore:"*":.env.pre.*"*".env.pre.Ab12Cd" ]]
  [[ "${lines[1]}" == ".gitignore:"*":.env.tmp.*"*".env.tmp.Ab12Cd" ]]
}

@test "D4: SIGTERM at 40+ points of set_env_var / remove_env_var leaves no .env.pre.* or .env.tmp.* behind" {
  local i p rc left=0 killed=0 hung=0
  for ((i = 0; i < 44; i++)); do
    seq 1 40 | sed 's/.*/K&=v&/' > "$SB/.env"
    bash -c 'source "$1"; set +e; ROOT_DIR="$2"
      while :; do set_env_var K7 "v$RANDOM" >/dev/null 2>&1; remove_env_var K9 >/dev/null 2>&1; set_env_var K9 x >/dev/null 2>&1; done' _ "$REPO_ROOT/haven" "$SB" &
    p=$!
    sleep "0.$((i % 9))$((RANDOM % 10))"
    kill -TERM "$p"
    for ((w = 0; w < 50; w++)); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$p" 2>/dev/null; then hung=$((hung + 1)); kill -KILL "$p"; fi
    rc=0; wait "$p" || rc=$?
    (( rc == 143 )) && killed=$((killed + 1))
    if [ -n "$(find "$SB" -maxdepth 1 \( -name '.env.pre.*' -o -name '.env.tmp.*' \) -print -quit)" ]; then
      left=$((left + 1)); find "$SB" -maxdepth 1 \( -name '.env.pre.*' -o -name '.env.tmp.*' \) -delete
    fi
  done
  echo "runs=44 exit143=$killed hung=$hung with_leftovers=$left"
  [ "$hung" -eq 0 ]
  [ "$killed" -eq 44 ]
  [ "$left" -eq 0 ]
}

@test "D4: a signal during the write waits for its end and then meets the trap that was there before" {
  printf 'A=1\n' > "$SB/.env"
  run in_haven '
    trap "echo PREVIOUS-TERM-TRAP" TERM
    cat() { kill -TERM $BASHPID; command cat "$@"; }   # the TERM lands while the snapshot is written
    set_env_var B 2; echo "rc=$?"; unset -f cat
    trap -p TERM; ls -a "$S" | grep -c "^\.env\.\(pre\|tmp\)\." ; grep -c "" "$S/.env"'
  echo "$output"
  [ "${lines[0]}" = "PREVIOUS-TERM-TRAP" ]
  [ "${lines[1]}" = "rc=0" ]
  [ "${lines[2]}" = "trap -- 'echo PREVIOUS-TERM-TRAP' SIGTERM" ]
  [ "${lines[3]}" = "0" ]
  [ "${lines[4]}" = "2" ]
}

# --- R1: a captured write never runs the parent's (the TUI's) trap actions ---
# `trap -p` in a subshell lists the parent's traps; the writer guard saved and
# put back that list, and the subshell's exit ran the TUI's EXIT action (stty
# on the live terminal). Each parent action appends its name and the pid it
# runs in to a marker file; only lines from another pid than the parent count
# (bash itself runs the parent's INT trap when a child dies of SIGINT).
R1_PARENT_TRAPS='m="$S/ran"; : > "$m"; parent=$BASHPID
    for s in EXIT INT TERM HUP; do trap "echo $s \$BASHPID >> \"\$m\"" "$s"; done
    in_subshells() { grep -vc " $parent\$" "$m"; }'

@test "R1: a captured set_env_var/remove_env_var runs none of the parent's EXIT/INT/TERM/HUP actions in its subshell" {
  printf 'A=1\n' > "$SB/.env"
  run in_haven "$R1_PARENT_TRAPS"'
    write_then() { set_env_var B "$RANDOM" || return 9; kill -s "$1" "$BASHPID"; }
    run_capture set_env_var B 2; echo "set status=$RUN_STATUS"
    run_capture remove_env_var B; echo "remove status=$RUN_STATUS"
    for s in INT TERM HUP; do run_capture write_then "$s"; echo "$s status=$RUN_STATUS"; done
    echo "parent actions run in the subshells: $(in_subshells)"
    trap -p EXIT | grep -c "echo EXIT"; cat "$m"'
  echo "$output"
  [ "${lines[0]}" = "set status=0" ]
  [ "${lines[1]}" = "remove status=0" ]
  [ "${lines[2]}" = "INT status=130" ]
  [ "${lines[3]}" = "TERM status=143" ]
  [ "${lines[4]}" = "HUP status=129" ]
  [ "${lines[5]}" = "parent actions run in the subshells: 0" ]
  [ "${lines[6]}" = "1" ]   # the parent's own EXIT trap is still in place
}

@test "R1: ensure_docker_uid writing inside a captured prepare runs none of the parent's trap actions" {
  printf 'A=1\n' > "$SB/.env"
  run in_haven "$R1_PARENT_TRAPS"'
    run_capture tui_prepare_start_quiet; echo "status=$RUN_STATUS"
    grep -c "^DOCKER_[UG]ID=" "$S/.env"
    echo "parent actions run in the subshell: $(in_subshells)"; cat "$m"'
  echo "$output"
  [ "${lines[0]}" = "status=0" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "parent actions run in the subshell: 0" ]
}

@test "R1: run_capture keeps an ignored signal ignored (that disposition is inherited)" {
  run in_haven '
    trap "" INT
    run_capture trap -p INT; echo "[$RUN_OUTPUT]"
    run_capture trap -p EXIT TERM HUP; echo "[$RUN_OUTPUT]"'
  echo "$output"
  [ "${lines[0]}" = "[trap -- '' SIGINT]" ]
  [ "${lines[1]}" = "[]" ]
}

@test "R1: the TUI's EXIT and INT/TERM actions do nothing in a subshell, even when a write there armed them" {
  printf 'A=1\n' > "$SB/.env"
  run in_haven '
    m="$S/ran"; : > "$m"
    tui_cleanup() { echo "cleanup in $BASHPID" >> "$m"; }
    tui_restore_tty() { echo "restore in $BASHPID" >> "$m"; }
    TUI_PID=$BASHPID; trap tui_on_exit EXIT; trap tui_on_signal INT TERM
    ( set_env_var B 2 ); echo "plain subshell rc=$?"
    ( set_env_var B 3; kill -TERM $BASHPID ); echo "signalled subshell rc=$?"
    echo "actions in subshells: $(grep -c "" "$m")"
    tui_on_exit; grep -c "in $BASHPID\$" "$m"'
  echo "$output"
  [ "${lines[0]}" = "plain subshell rc=0" ]
  [ "${lines[1]}" = "signalled subshell rc=130" ]
  [ "${lines[2]}" = "actions in subshells: 0" ]
  [ "${lines[3]}" = "2" ]   # in the TUI's own process they still act
}

# --- R2: no default-action window while the writer guard puts the traps back ---
# A `trap` stand-in (a shell function shadowing the builtin, defined only in
# the test) passes every call through and, on the k-th call made from
# writer_guard_off, sends one TERM to the process right after it. Every k from
# 1 to the number of calls is run, so the TERM lands at every point between the
# restore steps. Before the fix the first call was `trap - EXIT INT TERM HUP`,
# and a TERM there got the default action.
R2_TRAP_STANDIN='N=0
    trap() {
      builtin trap "$@"; local rc=$?
      if [[ "${FUNCNAME[1]:-}" == writer_guard_off ]]; then
        N=$((N + 1)); (( N != K )) || { echo sent >> "$S/sent"; kill -TERM "$BASHPID"; }
      fi
      return "$rc"
    }'

@test "R2: a TERM at any point while the writer guard restores the traps runs the outer handler, and no temp file stays" {
  local k
  for k in 1 2 3 4; do   # four restore steps: EXIT, INT, TERM, HUP
    printf 'A=1\n' > "$SB/.env"; rm -f "$SB/sent" "$SB/outer"
    run in_haven 'K='"$k"'
      builtin trap "echo OUTER >> \"\$S/outer\"" TERM
      '"$R2_TRAP_STANDIN"'
      set_env_var B 2; echo "rc=$?"; unset -f trap
      echo "after the write"'
    echo "k=$k status=$status sent=$(cat "$SB/sent" 2>/dev/null) outer=$(grep -c "" "$SB/outer" 2>/dev/null) $output"
    [ -e "$SB/sent" ]
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0
after the write" ]
    [ "$(grep -c "" "$SB/outer")" -eq 1 ]
    [ -z "$(find "$SB" -maxdepth 1 \( -name '.env.pre.*' -o -name '.env.tmp.*' \) -print -quit)" ]
    grep -qx 'B=2' "$SB/.env"
  done
}

@test "D5: run_capture runs with TUI_ACTIVE=0: a die inside does not run tui_cleanup, the error is in the output" {
  run in_haven '
    TUI_ACTIVE=1
    tui_cleanup() { echo CLEANUP-RAN-IN-THE-CAPTURE; }
    run_capture require_compose_file "$S/no-such-compose.yml"
    echo "status=$RUN_STATUS active=$TUI_ACTIVE"; printf "%s\n" "$RUN_OUTPUT"' 2>&1
  echo "$output"
  [ "${lines[0]}" = "status=1 active=1" ]
  [[ "${lines[1]}" == *"ERROR"*"Compose file not found: $SB/no-such-compose.yml" ]]
  [[ "$output" != *CLEANUP-RAN* ]]
}

@test "D5: the TUI's Start with a missing compose file shows the error in its box, text only" {
  printf 'RELAY_URL=r\n' > "$SB/.env"
  run in_haven '
    TUI_ACTIVE=1 FOLLOW_LOGS=0 COMPOSE_FILE_PLAIN="$S/docker-compose.yml"
    tui_cleanup() { echo CLEANUP-RAN; }
    tui_message() { printf "BOX[%s] %s\n" "$1" "$2"; }
    tui_refresh_logs_view() { :; }
    tui_run_action Start start_services plain'
  echo "$output"
  [ "$output" = "BOX[Start] Failed (exit 1)."$'\n\n'"ERROR Compose file not found: docker-compose.yml" ]
  [ ! -e "$SB/blossom" ]   # it stopped at the compose file, before any preparation
}

@test "P1: log_sanitize_line drops OSC 52, OSC 2 and other controls, keeps the text and the level word" {
  run in_haven '
    log_sanitize_line $'"'"'\e[33mWRN\e[0m a \e]52;c;SGVsbG8=\a b \e]2;PWNED\e\\ c\x9b2J\r'"'"'
    printf "[%s]\n" "$_SANITIZED"
    log_sanitize_line "MOCKLOG COUNTER=1"; printf "[%s]\n" "$_SANITIZED"'
  echo "$output"
  [ "${lines[0]}" = "[WRN a  b  c2J]" ]
  [ "${lines[1]}" = "[MOCKLOG COUNTER=1]" ]
}

@test "P5: a key set twice: every reader returns the LAST value, the one Compose uses" {
  printf 'DB_ENGINE=lmdb\nRELAY_URL=first.example\nA=1\nexport DB_ENGINE="badger" # later\nRELAY_URL="second.example"\n' > "$SB/.env"
  run in_haven '
    echo "read_env_var: $(read_env_var DB_ENGINE) $(read_env_var RELAY_URL)"
    echo "env_value_or_empty: $(env_value_or_empty DB_ENGINE) $(env_value_or_empty RELAY_URL)"
    env_effective_value RELAY_URL; echo "effective: $_EFFECTIVE lines=$_EFFECTIVE_LINES"
    env_values_load; echo "values_load: ${ENV_VALUE[DB_ENGINE]} ${ENV_VALUE[RELAY_URL]}"
    echo "engine_state: $(env_engine_state)"
    echo "last export line: $(env_key_lines DB_ENGINE | tail -n 1)"'
  echo "$output"
  [ "${lines[0]}" = 'read_env_var: "badger" "second.example"' ]
  [ "${lines[1]}" = "env_value_or_empty: badger second.example" ]
  [ "${lines[2]}" = 'effective: "second.example" lines=2' ]
  [ "${lines[3]}" = 'values_load: "badger" "second.example"' ]
  [ "${lines[4]}" = "engine_state: badger" ]
  [ "${lines[5]}" = 'last export line: export DB_ENGINE="badger" # later' ]
}

@test "P5: the start gate decides by the last DB_ENGINE line (lmdb then badger, badger data: open; badger then lmdb: closed)" {
  mkdir -p "$SB/db/private"
  : > "$SB/db/private/MANIFEST"
  printf 'DB_ENGINE=lmdb\nDB_ENGINE=badger\n' > "$SB/.env"
  run in_haven 'engine_mismatch_blocks && echo BLOCKED || echo OPEN'
  echo "$output"
  [ "${lines[-1]}" = "OPEN" ]
  printf 'DB_ENGINE=badger\nDB_ENGINE=lmdb\n' > "$SB/.env"
  run in_haven 'engine_mismatch_blocks && echo BLOCKED || echo OPEN'
  echo "$output"
  [ "${lines[-1]}" = "BLOCKED" ]
  [[ "$output" == *"runs the relay on lmdb (DB_ENGINE=lmdb)"* ]]
}

@test "P4: a \$ outside single quotes gets one sentence (\"a \$HOME b\", x\${Y}z); single-quoted and \$-free values none" {
  run in_haven '
    for v in "\"a \$HOME b\"" "x\${Y}z" "'"'"'a \$HOME b'"'"'" "plain value" "\"no dollar\""; do
      env_dollar_note "$v"; printf "%s => %s\n" "$v" "${_DOLLAR_NOTE:-none}"
    done'
  echo "$output"
  local s='Docker Compose expands $NAME and ${NAME} in this value (unquoted or in double quotes); put the value in single quotes to keep it literal.'
  [ "${lines[0]}" = "\"a \$HOME b\" => $s" ]
  [ "${lines[1]}" = "x\${Y}z => $s" ]
  [ "${lines[2]}" = "'a \$HOME b' => none" ]
  [ "${lines[3]}" = "plain value => none" ]
  [ "${lines[4]}" = "\"no dollar\" => none" ]
}

@test "P4: the sentence is in the details pane and in the box after the save; not for a single-quoted value" {
  mock_sandbox
  printf 'PRIVATE_RELAY_NAME="a $HOME b"\nPRIVATE_RELAY_ICON='"'"'x$y'"'"'\n' >> "$SB/.env"
  run in_mock '
    TUI_VIEW=env_item CURRENT_ENV_KEY=PRIVATE_RELAY_NAME; tui_setting_details; printf "%s " "${DETAIL_LINES[@]}"; echo
    CURRENT_ENV_KEY=PRIVATE_RELAY_ICON; tui_setting_details; printf "%s " "${DETAIL_LINES[@]}"; echo
    tui_env_save PRIVATE_RELAY_NAME "x\${Y}z"
    tui_env_save PRIVATE_RELAY_NAME "'"'"'x\${Y}z'"'"'"'
  echo "$output"
  [[ "$(tr -s ' ' <<<"${lines[0]}")" == *"Docker Compose expands \$NAME and \${NAME} in this value (unquoted or in double quotes); put the value in single quotes to keep it literal."* ]]
  [[ "${lines[1]}" != *"Docker Compose expands"* ]]
  local first="${output#*BOX[}"; first="${first%%BOX[*}" last="${output##*BOX[}"
  [[ "$first" == "Restart] .env was saved and the relay restarted (Plain) to apply it."* ]]
  [[ "$first" == *"Docker Compose expands \$NAME and \${NAME} in this value (unquoted or in double quotes); put the value in single quotes to keep it literal."* ]]
  [[ "$last" == "Restart] .env was saved and the relay restarted (Plain) to apply it."* && "$last" != *"Docker Compose expands"* ]]
  [ "$(grep -c 'Docker Compose expands' <<<"$output")" -eq 2 ]
}

@test "B1: the restore's sentences about what is already there match the measurement (notes skipped, lmdb media index listed once more)" {
  run grep -n -i -E 'never (deletes or )?duplicat|nor duplicat|or duplicated|never creates duplicates|skips what is already there' "$REPO_ROOT/haven" "$REPO_ROOT/README.md" "$REPO_ROOT/CHANGELOG.md"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qF 'Notes that are already there are skipped; on lmdb, a media index entry that is already there is listed once more (one more identical /list entry per restore).' "$REPO_ROOT/haven"
  grep -qF 'nothing was deleted, and notes that were already there were skipped. On lmdb, a media index entry that was already there is now listed once more.' "$REPO_ROOT/haven"
  grep -qF 'Notes that are' "$REPO_ROOT/README.md"
  tr '\n' ' ' < "$REPO_ROOT/README.md" | tr -s ' ' | grep -qF 'Notes that are already there are skipped. The media (Blossom) index behaves differently on lmdb: restored into a database that already lists a file, `/list/<pubkey>` shows that file once more per restore'
  tr '\n' ' ' < "$REPO_ROOT/CHANGELOG.md" | tr -s ' ' | grep -qF 'notes that are already there are skipped, while on lmdb a media (Blossom) index entry that is already there is listed once more per restore'
}

@test "B1: the TUI's restore confirmation says it when the database holds data, and only then" {
  run in_haven 'tui_confirm() { printf "confirm[%s]\n" "$1"; return 1; }; tui_flow_restore_pick b.zip'
  echo "$output"
  [ "$output" = "confirm[Restore b.zip? It adds the events of this backup that are missing and deletes nothing. A running relay stops while it runs and starts again afterwards.]" ]
  mkdir -p "$SB/db/private"; : > "$SB/db/private/data.mdb"
  run in_haven 'tui_confirm() { printf "confirm[%s]\n" "$1"; return 1; }; tui_flow_restore_pick b.zip'
  echo "$output"
  [ "$output" = "confirm[Restore b.zip? It adds the events of this backup that are missing and deletes nothing; events that exist only in the database stay. The database already holds data: notes that are already there are skipped, but on lmdb a media index entry that is already there is listed once more. A running relay stops while it runs and starts again afterwards.]" ]
}

@test "D4: an exit in the middle of the write removes the snapshot, then runs the EXIT trap that was there before" {
  printf 'A=1\n' > "$SB/.env"
  run bash -c '
    source "$1"; ROOT_DIR="$2"
    trap "echo PREVIOUS-EXIT-TRAP" EXIT
    env_write_check() { exit 7; }   # the snapshot exists at this point
    set_env_var B 2' _ "$REPO_ROOT/haven" "$SB"
  echo "$output"
  [ "$status" -eq 7 ]
  [ "$output" = "PREVIOUS-EXIT-TRAP" ]
  [ -z "$(find "$SB" -maxdepth 1 \( -name '.env.pre.*' -o -name '.env.tmp.*' \) -print -quit)" ]
}
