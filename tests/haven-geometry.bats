#!/usr/bin/env bats
# Frame geometry of the TUI, layer 1 (no tmux): the terminal size is stubbed
# through COLUMNS/LINES, ./haven is sourced, layout + frame + one view's
# painters run, and the byte stream is replayed by tests/term-emu.py (a small
# cursor-aware emulator, python3 -I). For every size and view: nothing is
# written beyond column COLS, every frame row ends exactly at column COLS, and
# ┬, the title-row divider, ┼ and ┴ share one column (LEFT_W).
# Also here: the scan for East Asian Wide/Fullwidth codepoints in ./haven.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EMU="$REPO_ROOT/tests/term-emu.py"

SIZES=(66x20 67x20 79x24 80x24 81x24 100x24 120x30 121x30 160x40 200x50 201x50)

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 missing (needed by the emulator and the scan)"
  TEST_DIR="$(mktemp -d)"
  # a sandbox ROOT_DIR: the menu reads .env and db/ from there, never the checkout's
  printf 'RELAY_URL="relay.example.org"\nDB_ENGINE="badger"\nWIDE_VALUE="設定値テスト"\n' > "$TEST_DIR/.env"
  mkdir -p "$TEST_DIR/db"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# paint <cols> <lines> <snippet> — the bytes of layout + frame + <snippet>
paint() {
  C="$1" L="$2" SNIP="$3" SB="$TEST_DIR" bash -c '
    export TERM=xterm-256color COLUMNS="$C" LINES="$L"
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$SB"
    TUI_DOCKER_OK=0 FOLLOW_LOGS=1 LOG_PID="" LOG_SERVICE=relay
    LOG_LINES=(); for ((i = 0; i < 60; i++)); do LOG_LINES+=("MOCKLOG COUNTER=$i"); done
    tui_collect_status() { TUI_STATUS_CACHE=("haven-relay: running up 2 hours" "image: -"); }
    tui_update_layout
    tui_draw_frame 0
    eval "$SNIP"
  '
}

# The views and the painters that draw their title row.
VIEW_main='TUI_VIEW=main; tui_render_left_menu; tui_render_right_logs'
VIEW_settings='TUI_VIEW=env_list; tui_render_left_menu; tui_render_right_logs'
VIEW_setting_key='TUI_VIEW=env_item; CURRENT_ENV_KEY=RELAY_URL; tui_render_left_menu; tui_render_right_logs'
VIEW_access='TUI_VIEW=json_files; tui_render_left_menu; tui_render_right_logs'
VIEW_status='TUI_VIEW=main; tui_render_left_menu; TUI_RIGHT_MODE=status; tui_render_right_status'
VIEW_filter='TUI_VIEW=main; tui_render_left_menu; LOG_FILTER=COUNTER=1; LOG_SCROLL=3; tui_render_right_logs'
# user data with wide characters in both titles: the painter itself must count cells
VIEW_wide='TUI_LEFT_TITLE="Haven / Settings / 日本語の設定キー名前日本語の設定"; TUI_RIGHT_TITLE="Logs 日本語ログ 世界 │ 中文字符 漢字"; tui_draw_title_row'
VIEW_list='TUI_VIEW=json_items; CURRENT_JSON_FILE=relays_import.json; tui_render_left_menu; tui_render_right_logs'
VIEWS=(main settings setting_key access list status filter wide)

# check_geometry <cols> <lines> <view> — empty output when the frame is right,
# otherwise one line per broken fact
check_geometry() {
  local cols="$1" lines="$2" view="$3" snip_var="VIEW_$3" report left_w r
  report="$(paint "$cols" "$lines" "${!snip_var}" | python3 -I "$EMU" "$cols" "$lines" frame)"
  left_w=$((cols * 38 / 100))
  (( left_w < 28 )) && left_w=28
  (( left_w > cols - 30 )) && left_w=$((cols - 30))
  grep -qx 'overflow 0' <<<"$report" || echo "$cols x $lines $view: $(grep '^overflow' <<<"$report" | tr '\n' ' ')"
  for ((r = 0; r <= lines - 2; r++)); do
    grep -qx "end $r $((cols - 1))" <<<"$report" || echo "$cols x $lines $view: row $r $(grep "^end $r " <<<"$report") (want col $((cols - 1)))"
  done
  grep -qx "first 0 ┌" <<<"$report" || echo "$cols x $lines $view: row 0 does not start with ┌"
  grep -qx "first 2 ├" <<<"$report" || echo "$cols x $lines $view: row 2 does not start with ├"
  grep -qx "first $((lines - 2)) └" <<<"$report" || echo "$cols x $lines $view: bottom row does not start with └"
  for ((r = 1; r <= lines - 3; r++)); do
    [[ "$r" == 2 ]] && continue
    grep -qx "first $r │" <<<"$report" || echo "$cols x $lines $view: row $r does not start with │"
  done
  grep -qx "junction $left_w $left_w $left_w $left_w" <<<"$report" \
    || echo "$cols x $lines $view: $(grep '^junction' <<<"$report") (want $left_w for all four)"
}

@test "geometry: every frame row ends at COLS and the four junctions share LEFT_W, all sizes and views" {
  local size cols lines view bad=""
  for size in "${SIZES[@]}"; do
    cols="${size%x*}" lines="${size#*x}"
    for view in "${VIEWS[@]}"; do
      bad+="$(check_geometry "$cols" "$lines" "$view")"$'\n'
    done
  done
  bad="${bad//$'\n\n'/$'\n'}"
  bad="${bad#$'\n'}"
  echo "$bad"
  [ -z "${bad//$'\n'/}" ]
}

@test "geometry: the emulator sees a frame that is one cell too wide (control)" {
  # control for the check above: a title row painted one cell wider than the
  # frame must show up as an overflow and a wrong row end
  local snip='TUI_VIEW=main; tui_render_left_menu; printf "\033[2;1H│ %*s│ %*s│" $((LEFT_W - 1)) "" $((TUI_COLS - LEFT_W - 3)) ""'
  VIEW_control="$snip"
  run check_geometry 80 24 control
  [[ "$output" == *"overflow 1"* ]]
  [[ "$output" == *"want 30 for all four"* ]]
}

@test "geometry: row 1 names the view (path), and the wide title stays inside its field" {
  local out
  out="$(paint 80 24 "$VIEW_main" | python3 -I "$EMU" 80 24 frame | grep '^title ')"
  [[ "$out" == "title │ Haven"*"│ Logs: relay"* ]]
  out="$(paint 80 24 "$VIEW_settings" | python3 -I "$EMU" 80 24 frame | grep '^title ')"
  [[ "$out" == "title │ Haven / Settings "*"│ Logs: relay"* ]]
  out="$(paint 120 30 "$VIEW_setting_key" | python3 -I "$EMU" 120 30 frame | grep '^title ')"
  [[ "$out" == "title │ Haven / Settings / RELAY_URL "* ]]
  out="$(paint 80 24 "$VIEW_access" | python3 -I "$EMU" 80 24 frame | grep '^title ')"
  [[ "$out" == "title │ Haven / Access lists "* ]]
  # too wide for its field, the path gives up leading segments before a word
  # is cut: the view you are in stays readable
  out="$(paint 80 24 "$VIEW_list" | python3 -I "$EMU" 80 24 frame | grep '^title ')"
  [[ "$out" == "title │ … / Import relays "*"│ Logs: relay"* ]]
  out="$(paint 120 30 "$VIEW_list" | python3 -I "$EMU" 120 30 frame | grep '^title ')"
  [[ "$out" == "title │ Haven / Access lists / Import relays "* ]]
  out="$(paint 80 24 "$VIEW_status" | python3 -I "$EMU" 80 24 frame | grep '^title ')"
  [[ "$out" == *"│ Status "* ]]
  # the wide left title loses its leading segments, then its last segment is
  # cut inside the 28-cell field (27 cells of text at most): "… / " (4 cells),
  # ten wide characters (20), "..." and the blank before the divider
  out="$(paint 80 24 "$VIEW_wide" | python3 -I "$EMU" 80 24 frame | grep '^title ')"
  [[ "$out" == "title │ … / 日本語の設定キー名前... │ Logs 日本語ログ"* ]]
}

# ---------- glyph policy: no East Asian Wide/Fullwidth codepoint ----------

# wide_codepoints <file> — "line U+XXXX" for every W/F codepoint, nothing when clean
wide_codepoints() {
  python3 -I -c '
import sys, unicodedata
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    for ch in line:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            print("%d U+%04X" % (n, ord(ch)))
' "$1"
}

@test "glyphs: ./haven contains no East Asian Wide or Fullwidth codepoint" {
  run wide_codepoints "$REPO_ROOT/haven"
  [ "$status" -eq 0 ]
  echo "$output"
  [ -z "$output" ]
}

@test "glyphs: the scan finds a wide codepoint planted in a copy (control)" {
  cp "$REPO_ROOT/haven" "$TEST_DIR/haven"
  printf '# planted: \xe2\x9a\xa1\n' >> "$TEST_DIR/haven"   # U+26A1 HIGH VOLTAGE SIGN
  run wide_codepoints "$TEST_DIR/haven"
  [ "$status" -eq 0 ]
  [[ "$output" == *" U+26A1" ]]
}
