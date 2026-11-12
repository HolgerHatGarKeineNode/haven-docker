#!/usr/bin/env bats
# The prompt accepts input longer than its field: the field is a window that
# follows the cursor, "…" marks hidden text at either end, and the full text is
# handed back. Layer 1: tui_prompt_window / tui_prompt_edit / tui_prompt_draw
# without a terminal (the drawn field replayed by tests/term-emu.py). Layer 2:
# the real tui_prompt in a pty (tests/pty-keys.py), keys typed and pasted.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EMU="$REPO_ROOT/tests/term-emu.py"
NPUB="npub1utx00neqgqln72j22kej3ux7803c2k986henvvha4thuwfkper4s7r50e8"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 missing (emulator and pty fixture)"
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# in_haven <snippet> — ./haven sourced, the size stubbed (COLS x ROWS, 80x24)
in_haven() {
  SNIP="$1" bash -c '
    export TERM=xterm-256color COLUMNS="${COLS:-80}" LINES="${ROWS:-24}"
    source '"$REPO_ROOT"'/haven
    set +e
    tui_update_layout
    eval "$SNIP"
  '
}

# keys_file <chunk...> — the chunks as the JSON list pty-keys.py reads
keys_file() {
  printf '%s\0' "$@" | python3 -I -c '
import json, sys
print(json.dumps(sys.stdin.buffer.read().decode("utf-8").split("\0")[:-1]))' > "$TEST_DIR/keys.json"
}

# prompt_in_pty <cols> <lines> — the real tui_prompt ("New value:") in a pty with
# the frame drawn first; the keys of keys.json; the handed-back value goes to
# $TEST_DIR/result, the terminal output to $TEST_DIR/screen
prompt_in_pty() {
  python3 -I "$REPO_ROOT/tests/pty-keys.py" "$1" "$2" "$TEST_DIR/keys.json" "$TEST_DIR/done" "$TEST_DIR/screen" \
    env -u COLUMNS -u LINES TERM=xterm-256color LC_ALL=C.UTF-8 R="$TEST_DIR" bash -c '
      source '"$REPO_ROOT"'/haven
      set +e
      stty -echo -icanon time 0 min 0
      tui_update_layout
      tui_draw_frame 0
      : > "$R/done.ready"
      v="$(tui_prompt "New value:" "")"
      printf "%s" "$v" > "$R/result"
      : > "$R/done"
      sleep 5'
}

# chunks <text> <n> — the text cut into pieces of n characters (typed keys
# arrive in bursts; each piece is read one character at a time)
chunks() {
  local t="$1" n="$2"
  while [[ -n "$t" ]]; do printf '%s\0' "${t:0:n}"; t="${t:n}"; done
}

# --- layer 1 ------------------------------------------------------------------

@test "prompt window: at the end of a 63-character npub the field shows its end, '…' first" {
  run in_haven '
    PI_TEXT="" PI_CUR=0 PI_VIEW=0; tui_prompt_widths
    tui_prompt_edit insert "'"$NPUB"'"
    tui_prompt_window 16; echo "end [$_PI_LMARK|$_PI_SHOWN|$_PI_RMARK] col=$_PI_CURCOL len=${#PI_TEXT}"
    tui_prompt_edit home
    tui_prompt_window 16; echo "home [$_PI_LMARK|$_PI_SHOWN|$_PI_RMARK] col=$_PI_CURCOL"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "end [1|wfkper4s7r50e8|0] col=15 len=63
home [0|npub1utx00neqgq|1] col=0" ]]
}

@test "prompt window: 2000 random edits keep the field inside its cells and the cursor visible" {
  run in_haven '
    RANDOM=4242
    words=(alpha beta "日本語" gamma "x" "設定値" delta "   " "abcdefghijklmnopqrstuvwxyz0123456789")
    bad=""
    for f in 4 10 16 23; do
      PI_TEXT="" PI_CUR=0 PI_VIEW=0; tui_prompt_widths
      for ((n = 0; n < 500; n++)); do
        case $((RANDOM % 9)) in
          0|1|2) tui_prompt_edit insert "${words[$((RANDOM % ${#words[@]}))]}" ;;
          3) tui_prompt_edit left ;; 4) tui_prompt_edit right ;; 5) tui_prompt_edit backspace ;;
          6) tui_prompt_edit home ;; 7) tui_prompt_edit end ;; 8) tui_prompt_edit word ;;
        esac
        tui_prompt_window "$f"
        _pi_cells "$PI_VIEW" $((PI_VIEW + ${#_PI_SHOWN}))
        used=$((_PI_LMARK + _N + _PI_RMARK))
        (( used <= f )) || bad+="f=$f n=$n used=$used; "
        (( _PI_CURCOL >= 0 && _PI_CURCOL < f )) || bad+="f=$f n=$n cursor col $_PI_CURCOL; "
        (( PI_CUR >= PI_VIEW && PI_CUR <= PI_VIEW + ${#_PI_SHOWN} )) || bad+="f=$f n=$n cursor outside; "
        [[ "$_PI_LMARK" == $(( PI_VIEW > 0 )) ]] || bad+="f=$f n=$n left mark; "
        [[ "$_PI_RMARK" == $(( PI_VIEW + ${#_PI_SHOWN} < ${#PI_TEXT} )) ]] || bad+="f=$f n=$n right mark; "
      done
    done
    echo "bad=[${bad:0:400}]"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "bad=[]" ]]
}

@test "prompt edit: cursor movement, Ctrl-W and Ctrl-U work beyond the visible field" {
  run in_haven '
    PI_TEXT="" PI_CUR=0 PI_VIEW=0; tui_prompt_widths
    tui_prompt_edit insert "alpha beta gamma delta epsilon zeta eta theta iota kappa"
    tui_prompt_window 10
    tui_prompt_edit home; for i in 1 2 3 4 5 6; do tui_prompt_edit right; done
    tui_prompt_edit insert X; tui_prompt_window 10
    tui_prompt_edit end; tui_prompt_edit word; tui_prompt_window 10
    echo "[$PI_TEXT] [$_PI_LMARK|$_PI_SHOWN|$_PI_RMARK]"
    tui_prompt_edit clear; tui_prompt_window 10; echo "[$PI_TEXT] cur=$PI_CUR view=$PI_VIEW"
    tui_prompt_edit insert "$(printf "z%.0s" $(seq 5000))"; echo "capped at ${#PI_TEXT}"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "[alpha Xbeta gamma delta epsilon zeta eta theta iota] [1|eta iota|0]
[] cur=0 view=0
capped at 4096" ]]
}

@test "prompt draw: the field with long ASCII and wide input never leaves its cells (emulator, 66x20 and 80x24)" {
  local size c l report bad=""
  for size in 66x20 80x24; do
    c="${size%x*}" l="${size#*x}"
    for t in "$NPUB" "設定値テスト日本語の設定キー名前日本語の設定abc" "abc設定値$NPUB設定"; do
      for cur in 0 5 30 end; do
        report="$(COLS=$c ROWS=$l in_haven '
          tui_draw_frame 0
          PI_TEXT="" PI_CUR=0 PI_VIEW=0; tui_prompt_widths
          tui_prompt_edit insert "'"$t"'"
          [[ "'"$cur"'" == end ]] || { tui_prompt_edit home; for ((i = 0; i < '"${cur/end/0}"'; i++)); do tui_prompt_edit right; done; }
          tui_prompt_draw $((TUI_LINES - 3)) "New value:"' | python3 -I "$EMU" "$c" "$l" frame)"
        grep -qx 'overflow 0' <<<"$report" || bad+="$size cur=$cur: overflow; "
        grep -qx "end $((l - 3)) $((c - 1))" <<<"$report" || bad+="$size cur=$cur: prompt row $(grep "^end $((l - 3)) " <<<"$report"); "
        grep -qx "last $((l - 3)) │" <<<"$report" || bad+="$size cur=$cur: prompt row border; "
      done
    done
  done
  echo "bad=[$bad]"
  [ -z "$bad" ]
}

# --- layer 2: the real prompt in a pty --------------------------------------------

@test "prompt (pty): a 63-character npub typed is handed back complete" {
  local -a k=()
  mapfile -d '' k < <(chunks "$NPUB" 8)
  keys_file "${k[@]}" $'\r'
  run prompt_in_pty 80 24
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "$NPUB" ]
}

@test "prompt (pty): a 63-character npub pasted (bracketed paste) is handed back complete" {
  keys_file $'\e[200~'"$NPUB"$'\e[201~' $'\r'
  run prompt_in_pty 80 24
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "$NPUB" ]
}

@test "prompt (pty): a 300-character value typed and one pasted are handed back complete" {
  local v
  v="$(python3 -I -c 'print("".join("abcdefghij0123456789-_.,"[i % 24] for i in range(300)))')"
  [ "${#v}" -eq 300 ]
  local -a k=()
  mapfile -d '' k < <(chunks "$v" 50)
  keys_file "${k[@]}" $'\r'
  run prompt_in_pty 80 24
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "$v" ]
  rm -f "$TEST_DIR/done" "$TEST_DIR/done.ready" "$TEST_DIR/result"
  keys_file $'\e[200~'"$v"$'\e[201~' $'\r'
  run prompt_in_pty 80 24
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "$v" ]
}

@test "prompt (pty): Home, Right, Ctrl-W and End act on the hidden part; Ctrl-U clears it all" {
  keys_file $'\e[200~alpha beta gamma delta epsilon zeta eta theta iota kappa\e[201~' \
    $'\e[H' $'\e[C' $'\e[C' $'\e[C' $'\e[C' $'\e[C' $'\e[C' X $'\e[F' $'\x17' $'\r'
  run prompt_in_pty 80 24
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "alpha Xbeta gamma delta epsilon zeta eta theta iota" ]
  rm -f "$TEST_DIR/done" "$TEST_DIR/done.ready" "$TEST_DIR/result"
  keys_file $'\e[200~'"$NPUB"$'\e[201~' $'\e[1~' $'\x15' o k $'\r'
  run prompt_in_pty 80 24
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "ok" ]
}

@test "prompt (pty): wide characters typed are handed back and the frame stays intact" {
  local t="設定値テスト日本語の設定キー名前abc日本語"
  local -a k=()
  mapfile -d '' k < <(chunks "$t" 3)
  keys_file "${k[@]}" $'\e[D' $'\e[D' Z $'\r'
  run prompt_in_pty 66 20
  [ "$output" = done ]
  [ "$(cat "$TEST_DIR/result")" = "設定値テスト日本語の設定キー名前abc日Z本語" ]
  local report
  report="$(python3 -I "$EMU" 66 20 frame < "$TEST_DIR/screen")"
  echo "$report" | grep -E '^(overflow|junction|end 17)'
  grep -qx 'overflow 0' <<<"$report"
  grep -qx 'end 17 65' <<<"$report"
  grep -qx 'junction 28 28 28 28' <<<"$report"
}
