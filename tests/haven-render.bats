#!/usr/bin/env bats
# tui_render_right_logs drawn without tmux: the escape stream of one render pass
# is cut into "<terminal row>:<text>" and compared as a whole. These pin the
# filtered window, where the hit-count row takes the first content row — until
# the fix the line index was not shifted, so the first line of the filtered
# window was never drawn (one match: banner and zero lines).
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# render <n-lines> <filter> [<scroll>] — the log panel's content rows (terminal
# rows 4..32 of a 120x34 screen, 29 content rows) after n lines
# "MOCKLOG COUNTER=<0..n-1>", scrolled back <scroll> lines (default 0 = live);
# one "row:text" per line, text trimmed, empty rows left out.
render() {
  N="$1" F="$2" S="${3:-0}" bash -c '
    export TERM=xterm-256color COLUMNS=120 LINES=34
    source '"$REPO_ROOT"'/haven
    set +e
    tui_update_layout
    LOG_LINES=(); for ((i = 0; i < N; i++)); do LOG_LINES+=("MOCKLOG COUNTER=$i"); done
    LOG_FILTER="$F"; LOG_SCROLL="$S"
    tui_render_right_logs
  ' | sed -E 's/\x1b\[([0-9]+);[0-9]+H/\n@\1:/g' \
    | grep -E '^@([4-9]|[12][0-9]|3[0-2]):' \
    | sed -E 's/\x1b\[[0-9;]*m//g; s/ +$//' \
    | grep -vE '^@[0-9]+:$'
}

@test "render: one match shows the banner and that one line" {
  run render 40 'COUNTER=7'
  [ "$status" -eq 0 ]
  [[ "$output" == $'@4:1 match(es) for \'COUNTER=7\' (/ resets)\n@5:MOCKLOG COUNTER=7' ]]
}

@test "render: a filtered window starts with its first line, every matching line follows in order" {
  # COUNTER=7 matches 7 and 70-79: eleven lines, fewer than the 28 body rows
  run render 80 'COUNTER=7'
  [ "$status" -eq 0 ]
  local want=$'@4:11 match(es) for \'COUNTER=7\' (/ resets)\n@5:MOCKLOG COUNTER=7'
  local i row=6
  for i in 70 71 72 73 74 75 76 77 78 79; do
    want+=$'\n'"@$row:MOCKLOG COUNTER=$i"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]
}

@test "render: more matches than rows keeps the newest line visible and drops the oldest" {
  # 60 matches, 28 body rows under the banner: COUNTER=32..59
  run render 60 'COUNTER='
  [ "$status" -eq 0 ]
  local want=$'@4:60 match(es) for \'COUNTER=\' (/ resets)'
  local i row=5
  for ((i = 32; i <= 59; i++)); do
    want+=$'\n'"@$row:MOCKLOG COUNTER=$i"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]
}

@test "render: no match shows only the banner" {
  run render 40 'COUNTER=77'
  [ "$status" -eq 0 ]
  [[ "$output" == $'@4:0 match(es) for \'COUNTER=77\' (/ resets)' ]]
}

@test "render: without a filter the full 29-row tail is drawn and no banner" {
  run render 60 ''
  [ "$status" -eq 0 ]
  local want="" i row=4
  for ((i = 31; i <= 59; i++)); do
    [[ -z "$want" ]] || want+=$'\n'
    want+="@$row:MOCKLOG COUNTER=$i"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]
}

@test "render: filter active and scrolled back keeps the banner row and the window's own first line" {
  # 120 lines, filter COUNTER=1: 31 matches (1, 10-19, 100-119), 28 body rows under the banner.
  # Scrolled 2 back the window is matches 1..28; scrolled past the top it clamps to
  # matches 0..27 — there the banner must not eat the first match (a window computed for
  # the full height drops it; in mid-scroll the two offsets cancel, so only the clamp shows it).
  local -a hits=()
  local i
  for ((i = 0; i < 120; i++)); do
    [[ "$i" == 1 || "$i" == 1[0-9] || "$i" == 1[0-9][0-9] ]] && hits+=("$i")
  done
  [ "${#hits[@]}" -eq 31 ]
  local banner=$'@4:31 match(es) for \'COUNTER=1\' (/ resets)'
  local want row k

  run render 120 'COUNTER=1' 2
  [ "$status" -eq 0 ]
  want="$banner" row=5
  for ((k = 1; k <= 28; k++)); do
    want+=$'\n'"@$row:MOCKLOG COUNTER=${hits[$k]}"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]

  run render 120 'COUNTER=1' 999
  [ "$status" -eq 0 ]
  want="$banner" row=5
  for ((k = 0; k < 28; k++)); do
    want+=$'\n'"@$row:MOCKLOG COUNTER=${hits[$k]}"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]
}

# render_after_pgup <n-lines> <filter> <presses> — like render, but the scroll
# position comes from pressing PgUp <presses> times (tui_handle_key), so the
# clamp of the key handler decides what the window shows
render_after_pgup() {
  N="$1" F="$2" P="$3" bash -c '
    export TERM=xterm-256color COLUMNS=120 LINES=34
    source '"$REPO_ROOT"'/haven
    set +e
    tui_update_layout
    LOG_LINES=(); for ((i = 0; i < N; i++)); do LOG_LINES+=("MOCKLOG COUNTER=$i"); done
    LOG_FILTER="$F"; LOG_SCROLL=0; TUI_RIGHT_MODE=logs
    for ((p = 0; p < P; p++)); do tui_handle_key pgup; done
    tui_render_right_logs
  ' | sed -E 's/\x1b\[([0-9]+);[0-9]+H/\n@\1:/g' \
    | grep -E '^@([4-9]|[12][0-9]|3[0-2]):' \
    | sed -E 's/\x1b\[[0-9;]*m//g; s/ +$//' \
    | grep -vE '^@[0-9]+:$'
}

@test "render: PgUp with a filter matching every line reaches the oldest line" {
  # 60 lines, all matching: 28 body rows under the banner. The clamp has to use the
  # filtered length and the filtered window height; against the full height (29) the
  # top stops one line short and COUNTER=0 is never drawn.
  run render_after_pgup 60 'COUNTER=' 10
  [ "$status" -eq 0 ]
  local want=$'@4:60 match(es) for \'COUNTER=\' (/ resets)' i row=5
  for ((i = 0; i < 28; i++)); do
    want+=$'\n'"@$row:MOCKLOG COUNTER=$i"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]
}

@test "render: PgUp with a filter matching some lines stops at the oldest match" {
  # 120 lines, filter COUNTER=1: 31 matches; the top window is matches 0..27
  run render_after_pgup 120 'COUNTER=1' 10
  [ "$status" -eq 0 ]
  local -a hits=()
  local i k
  for ((i = 0; i < 120; i++)); do
    [[ "$i" == 1 || "$i" == 1[0-9] || "$i" == 1[0-9][0-9] ]] && hits+=("$i")
  done
  local want=$'@4:31 match(es) for \'COUNTER=1\' (/ resets)' row=5
  for ((k = 0; k < 28; k++)); do
    want+=$'\n'"@$row:MOCKLOG COUNTER=${hits[$k]}"
    row=$((row + 1))
  done
  [[ "$output" == "$want" ]]
}
