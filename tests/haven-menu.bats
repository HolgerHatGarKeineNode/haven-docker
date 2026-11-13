#!/usr/bin/env bats
# The grouped main menu of the TUI: entries, order and groups; all of it on one
# screen at 80x24; navigation never rests on a group name; every shortcut
# letter runs what Enter runs on its entry; the state line drops whole fields
# instead of cutting a word; "Haven" once in rows 1-4.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EMU="$REPO_ROOT/tests/term-emu.py"

setup() {
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/db"
  printf 'DB_ENGINE="badger"\n' > "$TEST_DIR/.env"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# in_haven <snippet> — runs the snippet with ./haven sourced, ROOT_DIR in the
# test dir, docker reported offline (no docker call), the size stubbed to 80x24
in_haven() {
  SNIP="$1" SB="$TEST_DIR" bash -c '
    export TERM=xterm-256color COLUMNS="${COLS:-80}" LINES="${ROWS:-24}"
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$SB" SCRIPT_NAME=haven
    BACKUP_DIR="$SB/backups"
    TUI_DOCKER_OK=0
    tui_update_layout
    eval "$SNIP"
  '
}

# The specified menu: group names as "# <name>", entries as "<letter> <label>";
# "# " (no name) is the blank row that sets Help / About / Quit apart.
SPEC_MENU='# Relay
s Start
t Start with Tor
x Stop
r Restart
# Data
b Back up now
e Restore a backup
d Switch engine
i Import notes
# Configure
c Settings (.env)
l Access lists (JSON)
u Add missing settings
o Onion address
# 
? Help
a About
q Quit'

@test "menu: 15 entries in the specified order, in three groups plus the tail after a blank row" {
  run in_haven 'TUI_VIEW=main; tui_build_menu
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do
      if [[ "${MENU_IDS[$i]}" == group:* ]]; then echo "# ${MENU_LABELS[$i]}"; else echo "${MENU_KEYS[$i]} ${MENU_LABELS[$i]}"; fi
    done'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "$SPEC_MENU" ]]
  [ "$(grep -vc '^# ' <<<"$output")" -eq 15 ]
}

@test "menu: three group names with their state, a blank row and all 15 entries fit 80x24 without scrolling, no label cut" {
  run in_haven 'TUI_VIEW=main; tui_draw_frame 0; tui_render_left_menu; echo "OFFSET=$TUI_OFFSET" > "$SB/offset"'
  [ "$status" -eq 0 ]
  grep -qx 'OFFSET=0' "$TEST_DIR/offset"
  local screen label
  screen="$(printf '%s' "$output" | python3 -I "$EMU" 80 24 dump)"
  echo "$screen"
  # content rows 4..22 (1-based) hold exactly the menu: the relay state after
  # "Relay", the engine after "Data", the blank row before Help — and no label
  # is cut (no "..." / "…" anywhere in the pane)
  local rows
  rows="$(sed -n '4,22p' <<<"$screen" | sed -E 's/^│ ?//; s/│.*$//; s/ +$//; s/^▸ /  /')"
  local want
  want="$(sed -E 's/^# $//; t; s/^# (.*)/\1/; t; s/^/  /' <<<"$SPEC_MENU" \
    | sed -E 's/^Relay$/Relay  ○ Docker offline/; s/^Data$/Data  engine: badger/')"
  [[ "$rows" == "$want" ]]
  ! grep -qE '\.\.\.|…' <<<"$rows"
}

@test "menu: at 66x20 the visible entries all differ from each other" {
  COLS=66 ROWS=20 run in_haven 'TUI_VIEW=main; tui_draw_frame 0; tui_render_left_menu'
  [ "$status" -eq 0 ]
  local rows
  rows="$(printf '%s' "$output" | python3 -I "$EMU" 66 20 dump | sed -n '4,18p' \
    | sed -E 's/^│ ?//; s/│.*$//; s/ +$//; s/^▸ /  /' | grep '^  ' | sed -E 's/^  . //; s/\.\.\.$//')"
  echo "$rows"
  [ "$(wc -l <<<"$rows")" -eq 12 ]
  [ "$(sort -u <<<"$rows" | wc -l)" -eq 12 ]
}

@test "menu: no navigation key ever selects a group name" {
  run in_haven 'TUI_VIEW=main; tui_build_menu
    n=${#MENU_IDS[@]}; bad=""
    for key in up down k j home end g G 1 2 3 4 5 6 7 8 9; do
      for ((s = 0; s < n; s++)); do
        [[ "${MENU_IDS[$s]}" == group:* ]] && continue
        TUI_SEL=$s; tui_handle_key "$key"
        [[ "${MENU_IDS[$TUI_SEL]}" == group:* ]] && bad+="$key from $s -> ${MENU_IDS[$TUI_SEL]}; "
      done
    done
    echo "bad=[$bad]"
    sel() { echo "${MENU_LABELS[$TUI_SEL]}"; }
    TUI_SEL=4; tui_handle_key down; echo "down from Restart: $(sel)"
    tui_handle_key up; echo "up from Back up now: $(sel)"
    TUI_SEL=14; tui_handle_key j; echo "j from Onion address: $(sel)"
    tui_handle_key home; echo "home: $(sel)"
    tui_handle_key k; echo "k at the top: $(sel)"
    tui_handle_key G; echo "G: $(sel)"
    tui_handle_key g; echo "g: $(sel)"
    tui_handle_key end; echo "end: $(sel)"
    tui_handle_key 5; echo "digit 5: $(sel)"
    tui_handle_key 9; echo "digit 9: $(sel)"
    TUI_SEL=0; TUI_OFFSET=0; tui_render_left_menu >/dev/null; echo "first render: $(sel)"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "bad=[]
down from Restart: Back up now
up from Back up now: Restart
j from Onion address: Help
home: Start
k at the top: Start
G: Quit
g: Start
end: Quit
digit 5: Back up now
digit 9: Settings (.env)
first render: Start" ]]
}

# trace <how> <label-or-letter> — what one key does, with every action stubbed
# to a line naming it: "enter <label>" presses Enter on that entry, "letter <c>"
# presses the letter from the first entry.
TRACE_STUBS='
  tui_confirm() { echo "confirm[$1]"; return 1; }
  tui_message() { echo "message[$1|$2]"; }
  tui_set_view() { echo "view[$1]"; }
  show_help_screen() { echo "help-screen"; }
  tui_about() { echo "about-screen"; }
  tui_require_docker() { echo "require-docker"; return 0; }
  resolve_mode() { printf "plain"; }
  ensure_env_file() { return 0; }
  detect_json_tool() { return 0; }
  TUI_VIEW=main; tui_build_menu
'

@test "menu: each of the 15 letters runs exactly what Enter runs on its entry" {
  local letter label bad="" enter_t letter_t
  local -a seen=()
  while IFS= read -r line; do
    [[ "$line" == "# "* ]] && continue
    letter="${line%% *}" label="${line#* }"
    enter_t="$(in_haven "$TRACE_STUBS"'
      for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_LABELS[$i]}" == "'"$label"'" ]] && TUI_SEL=$i; done
      want=$TUI_SEL; tui_handle_key enter; echo "rc=$? sel=$want"')"
    letter_t="$(in_haven "$TRACE_STUBS"'
      TUI_SEL=1; tui_handle_key "'"$letter"'"; echo "rc=$? sel=$TUI_SEL"')"
    echo "[$letter] $label: enter=$(tr '\n' '|' <<<"$enter_t")"
    [[ "$enter_t" == "$letter_t" ]] || bad+="letter $letter: '$(tr '\n' '|' <<<"$letter_t")' vs Enter on '$label': '$(tr '\n' '|' <<<"$enter_t")'; "
    [[ "$enter_t" == *$'\n'* || "$label" == "Quit" ]] || bad+="Enter on '$label' did nothing visible; "
    # the action part (without the sel= of the entry) must differ between entries
    for prev in "${seen[@]}"; do
      [[ "$prev" == "${enter_t%sel=*}" ]] && bad+="'$label' runs the same as an earlier entry; "
    done
    seen+=("${enter_t%sel=*}")
  done <<<"$SPEC_MENU"
  echo "bad=[$bad]"
  [ -z "$bad" ]
}

@test "menu: the data entries open their guided flows" {
  # Back up asks first; Restore with no backups/ names the backup command;
  # Switch engine opens its overview. Nothing runs without a confirmation.
  run in_haven "$TRACE_STUBS"'
    tui_flow_run() { echo "run[$*]"; }
    for l in "Back up now" "Restore a backup" "Switch engine"; do
      for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_LABELS[$i]}" == "$l" ]] && TUI_SEL=$i; done
      tui_handle_enter
    done'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "confirm[Back up now? A verified copy of the relay database goes to backups/ in this directory. A running relay stops while it runs and starts again afterwards.]
message[Restore a backup|There is no backup in backups/ yet. Make one with Back up now, or with ./haven backup in a terminal.]
view[switch]" ]]
}

@test "menu: the relay state behind Relay drops whole fields from the right instead of cutting a word" {
  run in_haven '
    TUI_DOCKER_OK=1
    relay_container_running() { return 0; }
    resolve_mode() { printf tor; }
    tui_state_line; echo "80: [$MENU_STATE] [$MENU_ENGINE_NOTE] w=$LEFT_CONTENT_W"
    LEFT_CONTENT_W=21; tui_state_line; echo "21: [$MENU_STATE]"
    LEFT_CONTENT_W=20; tui_state_line; echo "20: [$MENU_STATE]"
    relay_container_running() { return 1; }; resolve_mode() { printf plain; }
    LEFT_CONTENT_W=25; tui_state_line; echo "stopped: [$MENU_STATE]"
    TUI_DOCKER_OK=0; tui_state_line; echo "offline: [$MENU_STATE] [$MENU_ENGINE_NOTE]"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "80: [● Running  Tor] [engine: badger] w=27
21: [● Running  Tor]
20: [● Running]
stopped: [○ Stopped  Plain]
offline: [○ Docker offline] [engine: badger]" ]]
}

@test "menu: the engine behind Data is the engine of the data on disk before .env" {
  mkdir -p "$TEST_DIR/db/private" && : > "$TEST_DIR/db/private/data.mdb"
  run in_haven 'tui_state_line; echo "[$MENU_ENGINE_NOTE]"'
  [ "$status" -eq 0 ]
  [[ "$output" == "[engine: lmdb]" ]]
}

@test "menu: rows 1-4 of the main view contain Haven at most once" {
  run in_haven 'LOG_LINES=(); TUI_VIEW=main; tui_draw_frame 0; tui_render_right_logs; tui_render_left_menu'
  [ "$status" -eq 0 ]
  local top
  top="$(printf '%s' "$output" | python3 -I "$EMU" 80 24 dump | sed -n '1,5p')"
  echo "$top"
  [ "$(grep -o Haven <<<"$top" | wc -l)" -eq 1 ]
}

@test "menu: with Docker offline an action shows the Docker message and the TUI stays open" {
  # each entry that needs the daemon: the message, then rc 0 (rc 1 ends the loop)
  run in_haven '
    TUI_ACTIVE=1
    docker() { [[ "$1" == info ]] && return 1; echo "docker $*"; }
    tui_message() { echo "message[$1|$2]"; }
    tui_confirm() { echo "confirm[$1]"; return 1; }
    TUI_VIEW=main; tui_build_menu
    for key in s t x r i; do TUI_SEL=1; tui_handle_key "$key"; echo "$key rc=$?"; done'
  echo "$output"
  [ "$status" -eq 0 ]
  local m="message[Docker|Docker daemon not reachable. Start Docker and try again.]"
  [[ "$output" == "$m
s rc=0
$m
t rc=0
$m
x rc=0
$m
r rc=0
$m
i rc=0" ]]
}

@test "settings: leaving the value prompt unchanged (Esc, empty Enter) writes nothing and restarts nothing" {
  printf 'DB_ENGINE="badger"\nRELAY_PORT=3355\n' > "$TEST_DIR/.env"
  run in_haven '
    TUI_ACTIVE=1
    # the write runs captured (tui_env_save): the stand-in reports to a file
    set_env_var() { echo "write[$1=$2]" >> "$SB/writes"; }
    restart_after_env_change() { echo "restart"; }
    tui_prompt() { printf "%s" "$2"; }   # Esc and an empty Enter hand back the default
    TUI_VIEW=env_item; CURRENT_ENV_KEY=RELAY_PORT; tui_build_menu
    TUI_SEL=0; tui_handle_enter; echo "same rc=$?"
    tui_prompt() { printf 4444; }       # a changed value is written and applied
    TUI_SEL=0; tui_handle_enter; echo "changed rc=$?"; cat "$SB/writes"'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "same rc=0
restart
changed rc=0
write[RELAY_PORT=4444]" ]]
}

@test "message box: a \\n written by the caller is a line break, not text" {
  run in_haven 'LOG_LINES=(); tui_wait_key() { :; }; tui_message "Title" "one\n\ntwo"'
  [ "$status" -eq 0 ]
  local rows
  rows="$(printf '%s' "$output" | python3 -I "$EMU" 80 24 dump | sed -n '4,8p' | sed -E 's/^│ ?//; s/│.*$//; s/ +$//')"
  echo "$rows"
  [[ "$rows" == "Title
───────────────────────────
one

two" ]]
}

@test "tui: a host without tput is told so before the terminal is touched" {
  run in_haven '
    stty() { echo "STTY-CALLED"; }
    tput() { echo "TPUT-CALLED"; }
    tui_init() { echo "INIT-REACHED"; exit 7; }   # a regression fails here instead of entering the loop
    command() { if [[ "$1" == "-v" && "$2" == "tput" ]]; then return 1; fi; builtin command "$@"; }
    tui_loop menu'
  [ "$status" -eq 1 ]
  [[ "$output" == *"the TUI needs tput, which is not installed on this host"* ]]
  [[ "$output" == *"./haven help lists them all."* ]]
  [[ "$output" != *"STTY-CALLED"* ]]
  [[ "$output" != *"TPUT-CALLED"* ]]
}
