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
  # Remove the .env the rig created for the env-editor path (CI checkouts
  # have none); a pre-existing user .env is never touched.
  if [[ "${ENV_CREATED:-0}" == "1" && -f "$ROOT_DIR/.env" ]]; then
    rm -f "$ROOT_DIR/.env"
  fi
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

# wait_for <session> <pattern> [timeout_s] — poll the capture until the
# pattern shows up; fixed sleeps are too fragile on slow CI runners.
wait_for() {
  local s="$1" pat="$2" t="${3:-10}" el=0 out=""
  while (( $(awk "BEGIN{print $el < $t}") )); do
    out="$(capture "$s")"
    [[ "$out" == *"$pat"* ]] && return 0
    sleep 0.3
    el=$(awk "BEGIN{print $el+0.3}")
  done
  return 1
}

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
# The env editor refuses to open without a .env (and asks interactively,
# which the raw-mode TUI cannot handle); create an empty one if the
# checkout has none — removed again in cleanup.
ENV_CREATED=0
if [[ ! -f "$ROOT_DIR/.env" ]]; then
  : > "$ROOT_DIR/.env"
  ENV_CREATED=1
fi
tmux_new t2 120 40 "./haven tui"
if ! wait_for t2 "Dashboard"; then
  bad "TUI did not reach the main view (startup)"
  tmux -L "$SOCK" kill-session -t t2 >/dev/null 2>&1 || true
else
tmux -L "$SOCK" send-keys -t t2 Down Down Down Down   # select ".env Editor"
sleep 0.3
tmux -L "$SOCK" send-keys -t t2 Enter                 # open env_list
wait_for t2 ".env" || true
sleep 0.3
tmux -L "$SOCK" send-keys -t t2 Enter                 # "Add variable" opens tui_prompt ("New key: ")
if ! wait_for t2 "New key"; then
  bad "prompt never opened before resize ($(capture t2 | tr '\n' '|' | head -c 160))"
else
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
fi
tmux -L "$SOCK" send-keys -t t2 Escape
sleep 0.2
tmux -L "$SOCK" send-keys -t t2 Escape
sleep 0.2
tmux -L "$SOCK" send-keys -t t2 Escape
sleep 0.5
tmux -L "$SOCK" kill-session -t t2 >/dev/null 2>&1 || true
fi

# --- 3: bracketed paste in the main view ------------------------------------
tmux_new t3 100 30 "TERM=xterm-256color ./haven tui"
if ! wait_for t3 "Haven"; then
  bad "TUI did not start for the paste check"
else
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
tmux -L "$SOCK" kill-session -t t4 >/dev/null 2>&1 || true

# --- helpers for the P3 engine checks ---------------------------------------

tui_pid() { # pid of the ./haven process inside session $1
  local shell_pid
  shell_pid="$(tmux -L "$SOCK" list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1)"
  [[ -n "$shell_pid" ]] && pgrep -P "$shell_pid" 2>/dev/null | head -1
}

cpu_ticks() { # utime+stime of pid $1 from /proc
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  awk '{print $14+$15}' <<<"${stat#*) }"
}

# --- 5: idle CPU — 150 ms poll vs the 50 ms baseline -------------------------
measure_idle_cpu() { # <session> — echoes ticks over a 5 s idle window
  local pid t0 t1
  sleep 1.5
  pid="$(tui_pid "$1")"
  [[ -n "$pid" ]] || { echo ""; return 1; }
  t0="$(cpu_ticks "$pid")"
  sleep 5
  t1="$(cpu_ticks "$pid")"
  echo "$((t1 - t0))"
}

mkdir -p "$WORK/old"
git -C "$ROOT_DIR" show 753dab5:haven > "$WORK/old/haven" 2>/dev/null
chmod +x "$WORK/old/haven"
tmux_new t5a 100 30 "PATH=$ROOT_DIR/tests/mock:\$PATH $WORK/old/haven tui"
wait_for t5a "Haven" || true
ticks_old="$(measure_idle_cpu t5a)"
tmux -L "$SOCK" kill-session -t t5a >/dev/null 2>&1 || true

tmux_new t5b 100 30 "PATH=$ROOT_DIR/tests/mock:\$PATH ./haven tui"
wait_for t5b "Haven" || true
ticks_new="$(measure_idle_cpu t5b)"
tmux -L "$SOCK" kill-session -t t5b >/dev/null 2>&1 || true

if [[ -n "${ticks_old:-}" && -n "${ticks_new:-}" ]]; then
  if (( ticks_new * 2 <= ticks_old )); then
    ok "idle CPU at 150 ms poll is at least half of the 50 ms baseline (${ticks_new} vs ${ticks_old} ticks/5s)"
  else
    bad "idle CPU not reduced enough: ${ticks_new} vs ${ticks_old} ticks/5s"
  fi
else
  bad "CPU measurement failed (old=${ticks_old:-none} new=${ticks_new:-none})"
fi

# --- 6: key latency below 300 ms ---------------------------------------------
tmux_new t6 100 30 "PATH=$ROOT_DIR/tests/mock:\$PATH ./haven tui"
wait_for t6 "Dashboard" || bad "TUI did not start for the latency check"
lat_ms=""
if capture t6 | grep -q "▸ Start (Docker)"; then
  t0_ns="$(date +%s%N)"
  tmux -L "$SOCK" send-keys -t t6 Down
  for _ in $(seq 1 100); do
    if capture t6 | grep -q "▸ Start (Tor)"; then
      t1_ns="$(date +%s%N)"
      lat_ms=$(( (t1_ns - t0_ns) / 1000000 ))
      break
    fi
    sleep 0.015
  done
fi
if [[ -n "$lat_ms" && "$lat_ms" -lt 300 ]]; then
  ok "key latency ${lat_ms} ms < 300 ms"
else
  bad "key latency measured ${lat_ms:-timeout} ms"
fi
tmux -L "$SOCK" kill-session -t t6 >/dev/null 2>&1 || true

# --- 7: producer death — panel refreshes within 2 s --------------------------
tmux_new t7 100 30 "PATH=$ROOT_DIR/tests/mock:\$PATH ./haven tui"
if ! wait_for t7 "COUNTER="; then
  bad "mock log stream did not reach the panel"
else
  mock_pid="$(pgrep -f "tests/mock/docker compose" | head -1)"
  if [[ -z "$mock_pid" ]]; then
    bad "no mock producer process found to kill"
  else
    kill "$mock_pid" 2>/dev/null
    sleep 2
    if capture t7 | grep -q "COUNTER=0"; then
      ok "panel restarted the stream within 2 s (fresh COUNTER=0 visible)"
    else
      bad "panel did not refresh after producer death ($(capture t7 | grep -c COUNTER) counter lines)"
    fi
  fi
fi
tmux -L "$SOCK" kill-session -t t7 >/dev/null 2>&1 || true

say ""
say "e2e-tui: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
