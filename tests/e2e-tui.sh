#!/usr/bin/env bash
# End-to-end checks for the TUI terminal I/O hardening (P2), driven through
# tmux so the plan's capture-based proofs are reproducible:
#   1. too-small terminal: message + untouched stty state
#   2. resize while a prompt is open: prompt redraws at the new geometry
#   3. bracketed paste in the main view: no back-navigation, TUI stays alive
#   4. die() while the TUI is active: message survives on the normal screen
#
# Run from the repository root:  ./tests/e2e-tui.sh
# Requires: tmux. Exits non-zero if any check fails.

set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="haven-e2e-$$"
WORK="$(mktemp -d)"
PASS=0
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "PASS: $*"; }
bad()  { FAIL=$((FAIL + 1)); say "FAIL: $*"; }

cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# tmux_new <session> <cols> <lines> <command...>
# Commands run through bash -c so the rig works regardless of the tmux
# server's default shell (e.g. fish, where $? is invalid).
tmux_new() {
  local name="$1" cols="$2" lines="$3"
  shift 3
  tmux -L "$SOCK" new-session -d -x "$cols" -y "$lines" -s "$name" "cd $ROOT_DIR && bash -c '$*'"
}

capture() { tmux -L "$SOCK" capture-pane -p -t "$1"; }
pane_dead() { tmux -L "$SOCK" list-panes -t "$1" -F '#{pane_dead}' 2>/dev/null | head -1; }

# --- 1: too-small terminal -------------------------------------------------
tmux_new t1 60 15 "stty -g > $WORK/stty-before; ./haven tui; echo \$? > $WORK/rc; stty -g > $WORK/stty-after; sleep 30"
sleep 2
out="$(capture t1)"
if [[ "$out" == *"too small"* && "$out" == *"66"* ]]; then
  ok "too-small terminal shows the size message"
else
  bad "too-small terminal message missing (got: $(printf '%s' "$out" | tr -d '\n' | head -c 120))"
fi
if [[ "$(cat "$WORK/rc" 2>/dev/null)" == "1" ]]; then
  ok "too-small terminal exits 1"
else
  bad "too-small terminal exit code: $(cat "$WORK/rc" 2>/dev/null)"
fi
if diff -q "$WORK/stty-before" "$WORK/stty-after" >/dev/null 2>&1; then
  ok "stty -g identical before/after (shell state untouched)"
else
  bad "stty state changed: $(diff "$WORK/stty-before" "$WORK/stty-after" 2>&1 | head -3)"
fi
tmux -L "$SOCK" kill-session -t t1 >/dev/null 2>&1 || true

# --- 2: resize while a prompt is open --------------------------------------
tmux_new t2 120 40 "./haven tui"
sleep 2
tmux -L "$SOCK" send-keys -t t2 Down Down Down Down   # select ".env Editor"
sleep 0.3
tmux -L "$SOCK" send-keys -t t2 Enter                 # open env_list
sleep 0.5
tmux -L "$SOCK" send-keys -t t2 Enter                 # "Add variable" opens tui_prompt ("New key: ")
sleep 0.5
tmux -L "$SOCK" resize-window -t t2 -x 80 -y 24
sleep 1.2
after="$(capture t2)"
# The prompt must sit inside the shrunk terminal: 1-based row <= 22 (TUI_LINES-2)
line_no="$(printf '%s\n' "$after" | grep -n -m1 'New key' | cut -d: -f1 || true)"
if [[ -n "$line_no" && "$line_no" -le 22 ]]; then
  ok "prompt redraws inside the new geometry (row $line_no <= 22)"
elif [[ -z "$line_no" ]]; then
  bad "prompt not visible after resize ($(printf '%s' "$after" | tr '\n' '|' | head -c 200))"
else
  bad "prompt outside the new geometry (row $line_no > 22)"
fi
tmux -L "$SOCK" send-keys -t t2 Escape
sleep 0.2
tmux -L "$SOCK" send-keys -t t2 Escape
sleep 0.2
tmux -L "$SOCK" send-keys -t t2 Escape
sleep 0.5
tmux -L "$SOCK" kill-session -t t2 >/dev/null 2>&1 || true

# --- 3: bracketed paste in the main view ------------------------------------
tmux_new t3 100 30 "TERM=xterm-256color ./haven tui"
sleep 2
alive_before="$(pane_dead t3)"
tmux -L "$SOCK" send-keys -t t3 -l $'\033[200~pasted-garbage\033[201~'
sleep 0.8
out="$(capture t3)"
alive_after="$(pane_dead t3)"
if [[ "$out" == *"Haven"* ]]; then
  ok "main view still rendered after bracketed paste"
else
  bad "main view lost after paste (last: $(printf '%s' "$out" | tr -d '\n' | head -c 80))"
fi
if [[ "$alive_after" != "1" && "$alive_before" != "1" ]]; then
  ok "TUI process still alive after bracketed paste"
else
  bad "TUI process died on paste (dead before=$alive_before after=$alive_after)"
fi
tmux -L "$SOCK" kill-session -t t3 >/dev/null 2>&1 || true

# --- 4: die() visible after TUI cleanup --------------------------------------
# Runs in a subshell so die()'s exit does not close the tmux window before
# the capture; sleep keeps the pane alive with the message on screen.
tmux_new t4 100 30 "( source ./haven; TUI_ACTIVE=1; TUI_STTY_ORIG=\$(stty -g); die boom-visible ); sleep 30"
sleep 1.5
out="$(capture t4)"
if [[ "$out" == *"boom-visible"* && "$out" == *"ERROR"* ]]; then
  ok "die() message visible on the normal screen"
else
  bad "die() message swallowed (got: $(printf '%s' "$out" | tr -d '\n' | head -c 120))"
fi

say ""
say "e2e-tui: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
