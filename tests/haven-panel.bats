#!/usr/bin/env bats
# Unit tests for the P5 panel QoL in ./haven: scrollback window, live
# filter, page-key scroll, and mode switching.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "log_append: ring buffer caps at 1000 lines" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    for ((i=1; i<=1005; i++)); do log_append "line$i"; done
    echo "count=${#LOG_LINES[@]} first=${LOG_LINES[0]} last=${LOG_LINES[999]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "count=1000 first=line6 last=line1005" ]]
}

@test "tui_log_view_lines: live window shows the tail" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    LOG_LINES=(); LOG_FILTER=""; LOG_SCROLL=0
    for ((i=1; i<=50; i++)); do LOG_LINES+=("l$i"); done
    tui_log_view_lines 10
    echo "live=$_VIEW_IS_LIVE start=$_VIEW_START first=${_VIEW_LINES[$_VIEW_START]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "live=1 start=40 first=l41" ]]
}

@test "tui_log_view_lines: scrolled window pins above the live end" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    LOG_LINES=(); LOG_FILTER=""; LOG_SCROLL=5
    for ((i=1; i<=50; i++)); do LOG_LINES+=("l$i"); done
    tui_log_view_lines 10
    echo "live=$_VIEW_IS_LIVE start=$_VIEW_START first=${_VIEW_LINES[$_VIEW_START]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "live=0 start=35 first=l36" ]]
}

@test "tui_log_view_lines: case-insensitive substring filter with match count" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    LOG_LINES=("ERROR one" "info two" "error three" "noise"); LOG_FILTER="error"; LOG_SCROLL=0
    tui_log_view_lines 10
    echo "matches=$_VIEW_MATCHES lines=${#_VIEW_LINES[@]} first=${_VIEW_LINES[0]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "matches=2 lines=2 first=ERROR one" ]]
}

@test "tui_handle_key: pgup/pgdn scroll the log buffer in logs mode" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    TUI_RIGHT_MODE=logs; RIGHT_CONTENT_HEIGHT=10; LOG_SCROLL=0
    LOG_LINES=(); for ((i=1; i<=30; i++)); do LOG_LINES+=("l$i"); done
    tui_handle_key pgup; a=$LOG_SCROLL
    tui_handle_key pgup; b=$LOG_SCROLL
    tui_handle_key pgdn; c=$LOG_SCROLL
    tui_handle_key pgdn; tui_handle_key pgdn; tui_handle_key pgdn; d=$LOG_SCROLL
    echo "scroll=$a,$b,$c,$d"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "scroll=9,18,9,0" ]]
}

@test "tui_handle_key: page keys are a no-op in status mode" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    TUI_RIGHT_MODE=status; RIGHT_CONTENT_HEIGHT=10; LOG_SCROLL=0
    tui_handle_key pgup; echo "scroll=$LOG_SCROLL"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "scroll=0" ]]
}

@test "tui_handle_key: tab toggles the right panel mode" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    MENU_IDS=(quit); TUI_RIGHT_MODE=logs
    tui_handle_key tab; a=$TUI_RIGHT_MODE
    tui_handle_key tab; b=$TUI_RIGHT_MODE
    echo "mode=$a,$b"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "mode=status,logs" ]]
}

@test "tui_collect_status: parses container states from docker ps -a" {
  PATH="$REPO_ROOT/tests/mock:$PATH"
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR='"$REPO_ROOT"'
    tui_collect_status
    printf "%s\n" "${TUI_STATUS_CACHE[@]}"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"haven-relay: running up 2 hours"* ]]
  [[ "$output" == *"haven-tor: exited"* ]]
  [[ "$output" == *"image: sha256:abcdef123456789…"* ]]
  [[ "$output" == *"db/:"* ]]
  [[ "$output" == *"blossom/:"* ]]
}
