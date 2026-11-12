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
