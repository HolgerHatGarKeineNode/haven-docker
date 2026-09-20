#!/usr/bin/env bats
# Unit tests for the extended key decoding in ./haven (P2):
# escape-sequence table, bracketed paste, unknown sequences must not
# navigate back. Run from the repository root:  bats tests/

# ---------- tui_read_key: escape sequences ----------

@test "tui_read_key: Home (ESC[H) maps to home, never esc" {
  run bash -c 'source haven; set +e; printf "\033[H" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=home" ]]
}

@test "tui_read_key: End (ESC[F) maps to end" {
  run bash -c 'source haven; set +e; printf "\033[F" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=end" ]]
}

@test "tui_read_key: PageUp (ESC[5~) maps to pgup" {
  run bash -c 'source haven; set +e; printf "\033[5~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=pgup" ]]
}

@test "tui_read_key: PageDown (ESC[6~) maps to pgdn" {
  run bash -c 'source haven; set +e; printf "\033[6~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=pgdn" ]]
}

@test "tui_read_key: Delete (ESC[3~) maps to del" {
  run bash -c 'source haven; set +e; printf "\033[3~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=del" ]]
}

@test "tui_read_key: F1 (ESCOP) maps to f1" {
  run bash -c 'source haven; set +e; printf "\033OP" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=f1" ]]
}

@test "tui_read_key: bare ESC still maps to esc" {
  run bash -c 'source haven; set +e; printf "\033" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=esc" ]]
}

@test "tui_read_key: unbound sequence (ESC[Z) maps to unknown, not esc" {
  run bash -c 'source haven; set +e; printf "\033Z" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=unknown" ]]
}

@test "tui_read_key: Insert (ESC[2~) maps to unknown, never into the paste path" {
  run bash -c 'source haven; set +e; printf "\033[2~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=unknown" ]]
}

@test "tui_read_key: 3-char sequence PgUp survives the finalizer collection" {
  run bash -c 'source haven; set +e; printf "\033[5~X" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=pgup" ]]
}

@test "tui_read_key: rxvt Home variant (ESC[7~) maps to home" {
  run bash -c 'source haven; set +e; printf "\033[7~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=home" ]]
}

# ---------- tui_read_key: bracketed paste ----------

@test "tui_read_key: bracketed paste yields the paste key and swallows the payload" {
  run bash -c 'source haven; set +e; printf "\033[200~pasted-text\033[201~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=paste" ]]
  [[ "$output" != *"esc"* ]]
}

@test "tui_read_key: empty bracketed paste still closes cleanly" {
  run bash -c 'source haven; set +e; printf "\033[200~\033[201~" | { tui_read_key; echo "k=$_KEY"; }'
  [ "$status" -eq 0 ]
  [[ "$output" == "k=paste" ]]
}

# ---------- tui_handle_key: no accidental back/quit ----------

@test "tui_handle_key: paste in the main view keeps the view and keeps the TUI running" {
  run bash -c 'source haven; set +e; TUI_VIEW=main; tui_handle_key paste; echo "rc=$? view=$TUI_VIEW"'
  [ "$status" -eq 0 ]
  [[ "$output" == "rc=0 view=main" ]]
}

@test "tui_handle_key: unknown sequence in the main view does not quit or go back" {
  run bash -c 'source haven; set +e; TUI_VIEW=logs; tui_handle_key unknown; echo "rc=$? view=$TUI_VIEW"'
  [ "$status" -eq 0 ]
  [[ "$output" == "rc=0 view=logs" ]]
}

@test "tui_handle_key: del and f1 in a subview do not navigate back" {
  run bash -c 'source haven; set +e; TUI_VIEW=env_list; tui_handle_key del; r1=$?; TUI_VIEW=env_list; tui_handle_key f1; r2=$?; echo "r=$r1/$r2 view=$TUI_VIEW"'
  [ "$status" -eq 0 ]
  [[ "$output" == "r=0/0 view=env_list" ]]
}
