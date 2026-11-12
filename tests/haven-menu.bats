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
    TUI_DOCKER_OK=0
    tui_update_layout
    eval "$SNIP"
  '
}

# The specified menu: group names as "# <name>", entries as "<letter> <label>".
SPEC_MENU='# Relay
s Start
t Start with Tor
x Stop
r Restart
# Data
b Back up now
e Restore a backup
d Switch database engine
i Import notes
# Configure
c Settings (.env)
l Access lists (JSON)
u Update settings from template
o Onion address
? Help
a About
q Quit'

@test "menu: 15 entries in the specified order, in three groups plus the ungrouped tail" {
  run in_haven 'TUI_VIEW=main; tui_build_menu
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do
      if [[ "${MENU_IDS[$i]}" == group:* ]]; then echo "# ${MENU_LABELS[$i]}"; else echo "${MENU_KEYS[$i]} ${MENU_LABELS[$i]}"; fi
    done'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "$SPEC_MENU" ]]
  [ "$(grep -vc '^# ' <<<"$output")" -eq 15 ]
}

@test "menu: state line, three group names and all 15 entries fit 80x24 without scrolling" {
  run in_haven 'TUI_VIEW=main; tui_draw_frame 0; tui_render_left_menu; echo "OFFSET=$TUI_OFFSET" > "$SB/offset"'
  [ "$status" -eq 0 ]
  grep -qx 'OFFSET=0' "$TEST_DIR/offset"
  local screen label
  screen="$(printf '%s' "$output" | python3 -I "$EMU" 80 24 dump)"
  echo "$screen"
  # content rows 4..22 (1-based) hold exactly: the state line, then the menu
  local rows
  rows="$(sed -n '4,22p' <<<"$screen" | sed -E 's/^│ ?//; s/│.*$//; s/ +$//; s/^▸ /  /')"
  [ "$(sed -n 1p <<<"$rows")" == "○ Docker offline  badger" ]
  local want
  # the one label wider than the 27-cell pane is cut by the menu's truncation
  want="$(sed -E 's/^# (.*)/\1/; t; s/^/  /; s/Update settings from template/Update settings from.../' <<<"$SPEC_MENU")"
  [[ "$(sed -n '2,19p' <<<"$rows")" == "$want" ]]
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

@test "menu: the data entries name their CLI command in one sentence" {
  run in_haven "$TRACE_STUBS"'
    for l in "Back up now" "Restore a backup" "Switch database engine"; do
      for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_LABELS[$i]}" == "$l" ]] && TUI_SEL=$i; done
      tui_handle_enter
    done'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "message[Back up now|To back up the database, run ./haven backup in a terminal.]
message[Restore a backup|To restore a backup, run ./haven restore <file> in a terminal.]
message[Switch database engine|To move the data to the other engine, run ./haven db-switch <badger|lmdb> in a terminal.]" ]]
}

@test "menu: the state line drops whole fields from the right instead of cutting a word" {
  run in_haven '
    TUI_DOCKER_OK=1
    relay_container_running() { return 0; }
    resolve_mode() { printf tor; }
    tui_state_line; echo "80: [$MENU_STATE] w=$LEFT_CONTENT_W"
    LEFT_CONTENT_W=18; tui_state_line; echo "18: [$MENU_STATE]"
    LEFT_CONTENT_W=12; tui_state_line; echo "12: [$MENU_STATE]"
    relay_container_running() { return 1; }; resolve_mode() { printf plain; }
    LEFT_CONTENT_W=27; tui_state_line; echo "stopped: [$MENU_STATE]"
    TUI_DOCKER_OK=0; tui_state_line; echo "offline: [$MENU_STATE]"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "80: [● Running  Tor  badger] w=27
18: [● Running  Tor]
12: [● Running]
stopped: [○ Stopped  Plain  badger]
offline: [○ Docker offline  badger]" ]]
}

@test "menu: the state line names the engine of the data on disk before .env" {
  mkdir -p "$TEST_DIR/db/private" && : > "$TEST_DIR/db/private/data.mdb"
  run in_haven 'tui_state_line; echo "[$MENU_STATE]"'
  [ "$status" -eq 0 ]
  [[ "$output" == "[○ Docker offline  lmdb]" ]]
}

@test "menu: rows 1-4 of the main view contain Haven at most once" {
  run in_haven 'LOG_LINES=(); TUI_VIEW=main; tui_draw_frame 0; tui_render_right_logs; tui_render_left_menu'
  [ "$status" -eq 0 ]
  local top
  top="$(printf '%s' "$output" | python3 -I "$EMU" 80 24 dump | sed -n '1,5p')"
  echo "$top"
  [ "$(grep -o Haven <<<"$top" | wc -l)" -eq 1 ]
}
