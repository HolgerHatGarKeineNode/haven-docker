#!/usr/bin/env bash
# End-to-end checks of the TUI, driven through tmux so the capture-based
# proofs are reproducible:
#   1. too-small terminal: message + untouched stty state
#   2. resize while a prompt is open: prompt redraws at the new geometry
#   3. bracketed paste in the main view: no back-navigation, TUI stays alive
#   4. die() while the TUI is active: message survives on the normal screen
#   5-7. idle CPU, key latency, log producer death
#   8. navigation keys; 9-11. prompt editor, masking, inline validation
#   12. log scrollback, filter, status view; 13. about screen, env write backup
#
# Isolation (enforced here, not requested): every check runs in its OWN copy of
# the repository's tracked files under a temp dir, with .env.example as .env, a
# scripted mock docker forced to the front of PATH, a private tmux server
# (own socket, no user config) and a pinned TERM / LC_ALL. Nothing in the real
# working tree is read for writing; the rig proves that at the end by comparing
# fingerprints of the real .env and of db/ + blossom/ before and after.
#
# Waiting: no fixed sleeps in front of assertions. Checks poll for a condition
# (text on screen, selected row, file) with a generous bound; where a negative
# has to be settled, the TUI's HAVEN_TUI_SYNC_FILE render counter is used.
#
# Run from the repository root:  ./tests/e2e-tui.sh
# Requires: tmux, git. Exits non-zero if any check fails.

set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCK="test-haven-e2e-$$"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
WAIT_T="${E2E_WAIT_T:-30}"   # upper bound (s) for every condition poll
declare -A SBOF=()            # tmux session name -> its sandbox directory
SANDBOXES=()

# Pinned terminal environment of every pane (the tmux server inherits the
# caller's environment; the panes get exactly this on top).
PIN_TERM="xterm-256color"
PIN_LOCALE="C.UTF-8"

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "PASS: $*"; }
bad()  { FAIL=$((FAIL + 1)); say "FAIL: $*"; }

# One tmux server of our own: private socket, no user config.
tmx() { tmux -L "$SOCK" -f /dev/null "$@"; }

cleanup() {
  # Kills only the server on OUR socket, then whatever still runs from a
  # sandbox path of this run.
  tmx kill-server >/dev/null 2>&1 || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # the socket file outlives the server
  pkill -f -- "$WORK/" >/dev/null 2>&1 || true
  if [[ "${E2E_KEEP:-0}" == "1" ]]; then
    say "E2E_KEEP=1: sandboxes kept in $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- fingerprints of the real tree (hashes only, never content) -------------

fingerprint() {
  local env_hash data_hash status_hash
  if [[ -f "$ROOT_DIR/.env" ]]; then
    env_hash="$(sha256sum "$ROOT_DIR/.env" | cut -d' ' -f1)"
  else
    env_hash="none"
  fi
  data_hash="$(cd "$ROOT_DIR" && find db blossom -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
  status_hash="$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null | sha256sum | cut -d' ' -f1)"
  printf '%s %s %s' "$env_hash" "$data_hash" "$status_hash"
}
FP_BEFORE="$(fingerprint)"

# --- sandbox ----------------------------------------------------------------

# new_sandbox <name> — copy of the tracked files, .env from .env.example, state
# dir of the scripted docker mock seeded like the unscripted mock used to look
# (haven-relay up, haven-tor exited). Sets SB to the path (a global, not a
# command substitution: SANDBOXES must survive for the isolation proof).
new_sandbox() {
  local sb="$WORK/sb-$1" f
  mkdir -p "$sb/.rig"
  while IFS= read -r -d '' f; do
    [[ -f "$ROOT_DIR/$f" ]] || continue   # tracked but deleted in the work tree
    mkdir -p "$sb/$(dirname "$f")"
    cp -p "$ROOT_DIR/$f" "$sb/$f"
  done < <(git -C "$ROOT_DIR" ls-files -z)
  cp "$sb/.env.example" "$sb/.env"
  printf 'haven-relay\n' > "$sb/.rig/running"
  printf 'haven-tor\n' > "$sb/.rig/exited"
  SANDBOXES+=("$sb")
  SB="$sb"
}

# start_pane <session> <cols> <lines> <sandbox> <command...>
# The command runs through bash -c inside the sandbox with the mock first on
# PATH. @RIG@ in the command is replaced by the sandbox's .rig directory.
# SYNC=0 leaves HAVEN_TUI_SYNC_FILE unset (default: set, per session).
start_pane() {
  local name="$1" cols="$2" lines="$3" sb="$4" cmd inner
  shift 4
  cmd="$*"
  cmd="${cmd//@RIG@/$sb/.rig}"
  SBOF[$name]="$sb"
  inner="cd $(printf '%q' "$sb") && export TERM=$PIN_TERM LC_ALL=$PIN_LOCALE"
  inner+=" PATH=$(printf '%q' "$sb/tests/mock"):\$PATH"
  inner+=" MOCK_DOCKER_STATE_DIR=$(printf '%q' "$sb/.rig")"
  if [[ "${SYNC:-1}" == "1" ]]; then
    inner+=" HAVEN_TUI_SYNC_FILE=$(printf '%q' "$sb/.rig/sync-$name")"
  fi
  inner+=" && $cmd"
  tmx new-session -d -x "$cols" -y "$lines" -s "$name" "bash -c $(printf '%q' "$inner")"
}

kill_pane() { tmx kill-session -t "$1" >/dev/null 2>&1 || true; }

# --- polling helpers --------------------------------------------------------

capture()   { tmx capture-pane -p -t "$1"; }
pane_dead() { tmx list-panes -t "$1" -F '#{pane_dead}' 2>/dev/null | head -1; }

# poll_until <timeout_s> <command...> — true as soon as the command succeeds
poll_until() {
  local t="$1" deadline
  shift
  deadline=$(( $(date +%s%N) / 1000000 + t * 1000 ))
  while :; do
    "$@" && return 0
    (( $(date +%s%N) / 1000000 >= deadline )) && return 1
    sleep 0.05
  done
}

has_text() { local out; out="$(capture "$1")"; [[ "$out" == *"$2"* ]]; }
no_text()  { ! has_text "$1" "$2"; }
wait_for()    { poll_until "${3:-$WAIT_T}" has_text "$1" "$2"; }
wait_absent() { poll_until "${3:-$WAIT_T}" no_text "$1" "$2"; }

# The render counter of a session (0 while the file does not exist yet).
sync_n() {
  local f="${SBOF[$1]}/.rig/sync-$1" n
  n="$(cat "$f" 2>/dev/null)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
}

sync_reached() { [[ "$(sync_n "$1")" -ge "$2" ]]; }

# settle_after <session> <n0> — wait until two full render passes finished
# after the counter read n0 (taken BEFORE the key was sent). One pass is not
# enough: it may be a spinner pass that started before the key was read; the
# pass after that one has certainly seen the key.
settle_after() { poll_until "$WAIT_T" sync_reached "$1" "$(( $2 + 2 ))"; }

# send_settled <session> <tmux send-keys args...> — send, then wait until the
# TUI has rendered with the input applied.
send_settled() {
  local s="$1" n0
  shift
  n0="$(sync_n "$s")"
  tmx send-keys -t "$s" "$@"
  settle_after "$s" "$n0"
}

# goto_item <session> <label> [max_steps] — Down until "▸ <label>" is the
# selected row; bounded, false when the label never shows up.
goto_item() {
  local s="$1" label="$2" max="${3:-60}" i
  for ((i = 0; i <= max; i++)); do
    has_text "$s" "▸ $label" && return 0
    send_settled "$s" Down || return 1
  done
  return 1
}

# --- process helpers (the TUI process inside a session) ---------------------

tui_pid() {
  local shell_pid p cmd
  shell_pid="$(tmx list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1)"
  [[ -n "$shell_pid" ]] || return 1
  for p in $shell_pid $(pgrep -P "$shell_pid" 2>/dev/null); do
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" || continue
    [[ "$cmd" == bash\ -c* ]] && continue
    if [[ "$cmd" == *"haven tui"* ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

tui_pid_found() { tui_pid "$1" >/dev/null; }

cpu_ticks() { # utime+stime of pid $1 from /proc
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  # after "pid (comm) " field 1 is the state, so utime/stime are fields 12/13
  # (fields 14/15 are cutime/cstime: the CPU of reaped CHILDREN — that is what
  # this helper summed until 2026-11-11, 0 vs 1 tick at the 10 ms quantum)
  awk '{print $12+$13}' <<<"${stat#*) }"
}

# --- 1: too-small terminal -------------------------------------------------
new_sandbox t1
start_pane t1 60 15 "$SB" 'stty -g > @RIG@/stty-before; ./haven tui; echo $? > @RIG@/rc; stty -g > @RIG@/stty-after; sleep 30'
poll_until "$WAIT_T" test -s "$SB/.rig/stty-after"
out="$(capture t1)"
if [[ "$out" == *"too small"* && "$out" == *"66"* ]]; then
  ok "too-small terminal shows the size message"
else
  bad "too-small terminal message missing (got: $(printf '%s' "$out" | tr -d '\n' | head -c 120))"
fi
if [[ "$(cat "$SB/.rig/rc" 2>/dev/null)" == "1" ]]; then
  ok "too-small terminal exits 1"
else
  bad "too-small terminal exit code: $(cat "$SB/.rig/rc" 2>/dev/null)"
fi
if diff -q "$SB/.rig/stty-before" "$SB/.rig/stty-after" >/dev/null 2>&1; then
  ok "stty -g identical before/after (shell state untouched)"
else
  bad "stty state changed: $(diff "$SB/.rig/stty-before" "$SB/.rig/stty-after" 2>&1 | head -3)"
fi
kill_pane t1

# --- 2: resize while a prompt is open --------------------------------------
new_sandbox t2
start_pane t2 120 40 "$SB" './haven tui'
if ! wait_for t2 "Dashboard"; then
  bad "TUI did not reach the main view (startup)"
elif ! goto_item t2 ".env Editor"; then
  bad "menu entry '.env Editor' not reachable"
else
  tmx send-keys -t t2 Enter                             # open env_list
  wait_for t2 "Add variable"
  goto_item t2 "Add variable"
  tmx send-keys -t t2 Enter                             # "Add variable" opens tui_prompt ("New key: ")
  if ! wait_for t2 "New key"; then
    bad "prompt never opened before resize ($(capture t2 | tr '\n' '|' | head -c 160))"
  else
    row_before="$(capture t2 | grep -n -m1 'New key' | cut -d: -f1)"
    tmx resize-window -t t2 -x 80 -y 24
    # The prompt must sit inside the shrunk terminal: 1-based row <= 22
    # (TUI_LINES-2). Poll for exactly that end state.
    prompt_row_ok() {
      local n
      n="$(capture t2 | grep -n -m1 'New key' | cut -d: -f1)"
      [[ -n "$n" && "$n" -le 22 ]]
    }
    if ! [[ -n "$row_before" && "$row_before" -gt 22 ]]; then
      bad "resize check is vacuous: prompt already at row ${row_before:-none} <= 22 before the resize"
    elif poll_until "$WAIT_T" prompt_row_ok; then
      line_no="$(capture t2 | grep -n -m1 'New key' | cut -d: -f1)"
      ok "prompt redraws inside the new geometry (row $row_before -> $line_no <= 22)"
    else
      after="$(capture t2)"
      line_no="$(printf '%s\n' "$after" | grep -n -m1 'New key' | cut -d: -f1 || true)"
      if [[ -z "$line_no" ]]; then
        bad "prompt not visible after resize ($(printf '%s' "$after" | tr '\n' '|' | head -c 200))"
      else
        bad "prompt outside the new geometry (row $line_no > 22)"
      fi
    fi
    tmx send-keys -t t2 Escape
    wait_absent t2 "New key" 5 || true
  fi
fi
kill_pane t2

# --- 3: bracketed paste in the main view ------------------------------------
new_sandbox t3
start_pane t3 100 30 "$SB" './haven tui'
if ! wait_for t3 "Haven"; then
  bad "TUI did not start for the paste check"
else
  wait_for t3 "▸ Start (Docker)"
  alive_before="$(pane_dead t3)"
  tmx send-keys -t t3 -l $'\033[200~pasted-garbage\033[201~'
  # Barrier: keys are consumed in order, so once the Down below took effect the
  # paste has been fully handled.
  if goto_item t3 "Start (Tor)"; then
    barrier=1
  else
    barrier=0
  fi
  out="$(capture t3)"
  alive_after="$(pane_dead t3)"
  if [[ "$barrier" == "1" && "$out" == *"Haven"* ]]; then
    ok "main view still rendered after bracketed paste"
  else
    bad "main view lost after paste (barrier=$barrier, last: $(printf '%s' "$out" | tr -d '\n' | head -c 80))"
  fi
  if [[ "$alive_after" != "1" && "$alive_before" != "1" ]]; then
    ok "TUI process still alive after bracketed paste"
  else
    bad "TUI process died on paste (dead before=$alive_before after=$alive_after)"
  fi
fi
kill_pane t3

# --- 4: die() visible after TUI cleanup --------------------------------------
# Runs in a subshell so die()'s exit does not close the tmux window before
# the capture; sleep keeps the pane alive with the message on screen.
new_sandbox t4
SYNC=0 start_pane t4 100 30 "$SB" '( source ./haven; TUI_ACTIVE=1; TUI_STTY_ORIG=$(stty -g); die boom-visible ); sleep 30'
wait_for t4 "boom-visible" || true
out="$(capture t4)"
if [[ "$out" == *"boom-visible"* && "$out" == *"ERROR"* ]]; then
  ok "die() message visible on the normal screen"
else
  bad "die() message swallowed (got: $(printf '%s' "$out" | tr -d '\n' | head -c 120))"
fi
kill_pane t4

# --- 5: idle CPU — 150 ms poll vs the 50 ms baseline -------------------------
# Both versions run in a sandbox copy; the old one replaces ./haven there.
measure_idle_cpu() { # <session> — echoes ticks over a 5 s idle window
  local pid t0 t1
  # warmed up = the log stream reached the panel
  wait_for "$1" "COUNTER=" || { echo ""; return 1; }
  poll_until "$WAIT_T" tui_pid_found "$1" || { echo ""; return 1; }
  pid="$(tui_pid "$1")"
  t0="$(cpu_ticks "$pid")"
  sleep 5   # the measurement window itself
  t1="$(cpu_ticks "$pid")"
  echo "$((t1 - t0))"
}

new_sandbox t5a; SBO="$SB"
git -C "$ROOT_DIR" show 753dab5:haven > "$SBO/haven" 2>/dev/null
chmod +x "$SBO/haven"
SYNC=0 start_pane t5a 100 30 "$SBO" './haven tui'
ticks_old="$(measure_idle_cpu t5a)"
kill_pane t5a

new_sandbox t5b
SYNC=0 start_pane t5b 100 30 "$SB" './haven tui'
ticks_new="$(measure_idle_cpu t5b)"
kill_pane t5b

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
new_sandbox t6
SYNC=0 start_pane t6 100 30 "$SB" './haven tui'
# the selected menu entry as shown in the left pane (the right pane streams)
selected_entry() {
  capture t6 | grep -m1 '▸ ' | sed -E 's/^[^▸]*(▸ [^│]*).*$/\1/'
}
wait_for t6 "▸ " || bad "TUI did not start for the latency check"
lat_ms=""
sel0="$(selected_entry)"
if [[ -n "$sel0" ]]; then
  t0_ns="$(date +%s%N)"
  tmx send-keys -t t6 Down
  for _ in $(seq 1 2000); do
    sel1="$(selected_entry)"
    if [[ -n "$sel1" && "$sel1" != "$sel0" ]]; then
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
kill_pane t6
# seam unset: the TUI must not write a counter (nor a temp file) anywhere
if [[ -z "$(find "$SB" -name 'sync*' -print -quit)" ]]; then
  ok "HAVEN_TUI_SYNC_FILE unset: no render counter written"
else
  bad "render counter written although HAVEN_TUI_SYNC_FILE was unset"
fi

# --- 7: producer death — the panel restarts the stream -----------------------
new_sandbox t7
start_pane t7 100 30 "$SB" './haven tui'
# the first lines (COUNTER=0) must have scrolled out of the panel, otherwise
# seeing COUNTER=0 after the kill would prove nothing
if ! wait_for t7 "COUNTER=40"; then
  bad "mock log stream did not reach the panel"
elif has_text t7 "COUNTER=0 "; then
  bad "COUNTER=0 still on screen before the kill — restart check would be vacuous"
else
  # only the producer of THIS sandbox's mock: its argv carries the sandbox path
  mock_pid="$(pgrep -f -- "$SB/tests/mock/docker compose.* logs" | head -1)"
  if [[ -z "$mock_pid" ]]; then
    bad "no mock producer process found to kill"
  else
    kill "$mock_pid" 2>/dev/null
    t0_ms=$(( $(date +%s%N) / 1000000 ))
    if wait_for t7 "COUNTER=0"; then
      ok "panel restarted the stream after producer death (fresh COUNTER=0 visible after $(( $(date +%s%N) / 1000000 - t0_ms )) ms)"
    else
      bad "panel did not refresh after producer death ($(capture t7 | grep -c COUNTER) counter lines)"
    fi
  fi
fi
kill_pane t7

# --- 8: navigation keys (P4) --------------------------------------------------
new_sandbox t8
start_pane t8 100 30 "$SB" './haven tui'
if ! wait_for t8 "Dashboard"; then
  bad "TUI did not start for the navigation check"
else
  # nav_case <label> <description> — the selection has to END on the label
  nav_case() {
    if wait_for t8 "▸ $1" 10; then
      ok "navigation: $2 selects '$1'"
    else
      bad "navigation: $2 did not select '$1'"
    fi
  }
  if goto_item t8 "Stop services"; then
    send_settled t8 k;   nav_case "Start (Tor)" "k"
    send_settled t8 j;   nav_case "Stop services" "j"
    send_settled t8 G;   nav_case "Quit" "G"
    send_settled t8 g;   nav_case "Start (Docker)" "g"
    send_settled t8 End; nav_case "Quit" "End"
    send_settled t8 Home; nav_case "Start (Docker)" "Home"
  else
    bad "navigation: menu entry 'Stop services' not reachable"
  fi
fi
kill_pane t8

# NOTE: the digit shortcuts are proven at unit level (tests/haven-input.bats,
# "digit shortcuts select the nth entry directly"); an e2e case for them can
# only be index-based and is not kept here. PgUp/PgDn paged the menu until P4;
# P5 assigns them to the log scrollback — see check 12.

prompt_has_q() { capture t9 | grep 'New key' | grep -q 'Q'; }

# --- 9+10: prompt editor — paste, Ctrl-U, Ctrl-W (P4) -------------------------
# 160 cols so the 30-char paste fits the prompt's input budget.
new_sandbox t9
env_hash_t9="$(sha256sum "$SB/.env" | cut -d' ' -f1)"
start_pane t9 160 30 "$SB" './haven tui'
if ! wait_for t9 "Dashboard"; then
  bad "TUI did not start for the prompt editor check"
elif ! goto_item t9 ".env Editor"; then
  bad "menu entry '.env Editor' not reachable"
else
  tmx send-keys -t t9 Enter
  wait_for t9 "Add variable"
  goto_item t9 "Add variable"
  tmx send-keys -t t9 Enter  # -> "New key: " prompt
  if ! wait_for t9 "New key"; then
    bad "key prompt did not open"
  else
    # paste 30 characters through bracketed paste
    tmx send-keys -t t9 -l $'\033[200~abcdefghijklmnopqrstuvwxyz012345\033[201~'
    if wait_for t9 "abcdefghijklmnopqrstuvwxyz012345"; then
      ok "prompt: bracketed paste inserts the full 30-char payload"
    else
      bad "prompt: pasted payload missing ($(capture t9 | grep -o 'Tail lines.*' | head -c 60))"
    fi
    # Ctrl-U clears the line; the marker typed after it is the barrier that
    # proves the Ctrl-U was handled (input is consumed in order)
    tmx send-keys -t t9 C-u
    tmx send-keys -t t9 -l "Z9"
    wait_for t9 "Z9"
    if capture t9 | grep -q "abcdefghijklmnopqrstuvwxyz"; then
      bad "prompt: Ctrl-U did not clear the input"
    else
      ok "prompt: Ctrl-U clears the input"
    fi
    # Ctrl-W deletes the last word; again a marker closes the observation
    tmx send-keys -t t9 -l "foo bar"
    wait_for t9 "Z9foo bar"
    tmx send-keys -t t9 C-w
    tmx send-keys -t t9 -l "Q"
    poll_until "$WAIT_T" prompt_has_q
    # the prompt row only: "bar" must be gone, "foo" must stay (the
    # implementation also removes the blank in front of the deleted word)
    row="$(capture t9 | grep 'New key' | head -1)"
    if [[ "$row" == *"bar"* ]]; then
      bad "prompt: Ctrl-W did not delete the word"
    elif [[ "$row" == *"Z9foo"* && "$row" == *"Q"* ]]; then
      ok "prompt: Ctrl-W deletes the word before the cursor"
    else
      bad "prompt: Ctrl-W left unexpected input ($(printf '%s' "$row" | head -c 80))"
    fi
    # cancel the prompt — nothing must be written to .env
    tmx send-keys -t t9 Escape
    wait_absent t9 "New key" 10 || true
    if [[ "$(sha256sum "$SB/.env" | cut -d' ' -f1)" == "$env_hash_t9" ]]; then
      ok "cancelled prompt leaves .env byte-identical"
    else
      bad "cancelled prompt changed .env"
    fi
  fi
fi
kill_pane t9

# --- 11: masking, reveal, inline validation (P4) ------------------------------
# A small .env of its own keeps the list on one screen (no scrolling to find
# the entry); it lives in the sandbox like everything else.
new_sandbox t11
printf 'RELAY_URL="relay.example.org"\nTEST_SECRET_KEY=abcdefgh1234\n' > "$SB/.env"
env_hash_t11="$(sha256sum "$SB/.env" | cut -d' ' -f1)"
start_pane t11 100 30 "$SB" './haven tui'
if ! wait_for t11 "Dashboard"; then
  bad "TUI did not start for the masking check"
elif ! goto_item t11 ".env Editor"; then
  bad "menu entry '.env Editor' not reachable"
else
  tmx send-keys -t t11 Enter
  wait_for t11 "TEST_SECRET_KEY = "
  out="$(capture t11)"
  if [[ "$out" == *"TEST_SECRET_KEY = …1234"* && "$out" != *"abcdefgh1234"* ]]; then
    ok "env list masks sensitive values (…1234)"
  else
    bad "env list does not mask ($(printf '%s' "$out" | grep -o 'TEST_SECRET_KEY.*' | head -c 60))"
  fi
  # open the key, then reveal
  if goto_item t11 "TEST_SECRET_KEY"; then
    tmx send-keys -t t11 Enter
    wait_for t11 "Reveal value"
    goto_item t11 "Reveal value"
    tmx send-keys -t t11 Enter
    if wait_for t11 "abcdefgh1234"; then
      ok "reveal shows the plaintext on explicit request"
    else
      bad "reveal did not show the plaintext"
    fi
  else
    bad "env entry TEST_SECRET_KEY not reachable"
  fi
  tmx send-keys -t t11 x      # dismiss message
  wait_absent t11 "abcdefgh1234" 10 || true
  tmx send-keys -t t11 Escape # env_item -> env_list
  wait_for t11 "Add variable"
  goto_item t11 "Add variable"
  tmx send-keys -t t11 Enter
  wait_for t11 "New key"
  tmx send-keys -t t11 -l "RELAY_PORT"
  wait_for t11 "RELAY_PORT"
  tmx send-keys -t t11 Enter
  wait_for t11 "New value"
  tmx send-keys -t t11 -l "70000"
  wait_for t11 "70000"
  tmx send-keys -t t11 Enter
  if wait_for t11 "Port must be 1-65535"; then
    ok "invalid value shows the error inline at the prompt"
  else
    bad "inline validation message missing ($(capture t11 | tr '\n' '|' | head -c 150))"
  fi
  tmx send-keys -t t11 Escape # cancel value prompt
  wait_absent t11 "New value" 10 || true
fi
kill_pane t11
if [[ "$(sha256sum "$SB/.env" | cut -d' ' -f1)" == "$env_hash_t11" ]]; then
  ok ".env untouched by the cancelled add"
else
  bad ".env was modified by the cancelled add"
fi

# The filter prompt is open when its row shows the label without a filter text
# after it. (A submitted prompt leaves its row painted until the next prompt
# overwrites it, so the bare label is not enough to tell "open" from "stale".)
filter_prompt_ready() {
  capture t12 | grep 'Filter (empty clears):' | grep -qv 'COUNTER'
}

# --- 12: panel QoL — scrollback, filter, status view (P5) ---------------------
new_sandbox t12
start_pane t12 120 34 "$SB" './haven tui'
if ! wait_for t12 "COUNTER="; then
  bad "mock stream did not reach the panel for the P5 checks"
else
  # let the buffer fill past the visible height (34 rows -> ~28 visible)
  wait_for t12 "COUNTER=40"
  last_live="$(capture t12 | grep -o 'COUNTER=[0-9]*' | tail -1)"
  tmx send-keys -t t12 PgUp
  if wait_for t12 "paused"; then
    ok "PgUp pauses the panel and shows the pause banner"
  else
    bad "PgUp did not show the pause banner"
  fi
  older="$(capture t12 | grep -o 'COUNTER=[0-9]*' | tail -1)"
  if [[ "$older" != "$last_live" ]]; then
    ok "scrollback shows older lines ($older vs live $last_live)"
  else
    bad "scrollback still shows the live tail ($older)"
  fi
  tmx send-keys -t t12 PgDn
  if wait_absent t12 "paused"; then
    ok "PgDn resumes the live view"
  else
    bad "PgDn did not resume the live view"
  fi

  # live filter via slash
  tmx send-keys -t t12 /
  poll_until "$WAIT_T" filter_prompt_ready
  tmx send-keys -t t12 -l "COUNTER=2"
  wait_for t12 "COUNTER=2"
  n0="$(sync_n t12)"
  tmx send-keys -t t12 Enter
  if wait_for t12 "match(es) for 'COUNTER=2'"; then
    ok "slash search shows the live match count"
  else
    bad "slash search missing the match count ($(capture t12 | tr '\n' '|' | head -c 120))"
  fi
  settle_after t12 "$n0" || true
  if capture t12 | grep -q "COUNTER=3"; then
    bad "filter does not hide non-matching lines"
  else
    ok "filter hides non-matching lines"
  fi
  tmx send-keys -t t12 /
  poll_until "$WAIT_T" filter_prompt_ready
  tmx send-keys -t t12 Enter
  if wait_absent t12 "match(es)"; then
    ok "empty filter input clears the search"
  else
    bad "empty filter did not clear the search"
  fi

  # status panel via Tab
  tmx send-keys -t t12 Tab
  wait_for t12 "blossom/:" || true
  out="$(capture t12)"
  if [[ "$out" == *"Status"* && "$out" == *"running"* ]]; then
    ok "Tab switches to the status view (title + running container)"
  else
    bad "status view missing (title/running)"
  fi
  if [[ "$out" == *"haven-relay: running up 2 hours"* && "$out" == *"haven-tor: exited"* ]]; then
    ok "status lists container states and uptime"
  else
    bad "container states missing in the status view"
  fi
  if [[ "$out" == *"image: sha256:abcdef123456789…"* ]]; then
    ok "status shows the short image digest"
  else
    bad "image digest missing in the status view"
  fi
  if [[ "$out" == *"db/:"* && "$out" == *"blossom/:"* ]]; then
    ok "status shows du -sh for db/ and blossom/"
  else
    bad "directory sizes missing in the status view"
  fi
  tmx send-keys -t t12 Tab
  if wait_for t12 "COUNTER="; then
    ok "Tab switches back to the log view"
  else
    bad "Tab back did not restore the log view"
  fi
fi
if [[ "$(sync_n t12)" -gt 0 ]]; then
  ok "HAVEN_TUI_SYNC_FILE set: render counter advanced ($(sync_n t12) passes)"
else
  bad "render counter did not advance with HAVEN_TUI_SYNC_FILE set"
fi
kill_pane t12

# --- 13: P6 — about screen, timestamped backup on write, docs ---------------
new_sandbox t13
start_pane t13 120 30 "$SB" './haven tui'
if ! wait_for t13 "Dashboard"; then
  bad "TUI did not start for the P6 checks"
else
  if goto_item t13 "About"; then
    tmx send-keys -t t13 Enter
    wait_for t13 "Relay image digest:" || true
    out="$(capture t13)"
    if [[ "$out" == *"haven-docker CLI version:"* ]]; then
      ok "about screen shows the CLI version"
    else
      bad "about screen missing the CLI version"
    fi
    if [[ "$out" == *"Relay image digest:"* && "$out" == *"sha256:abcdef123456789…"* ]]; then
      ok "about screen shows the running image digest"
    else
      bad "about screen missing the image digest ($(printf '%s' "$out" | grep -o 'digest.*' | head -c 60))"
    fi
    tmx send-keys -t t13 x
    wait_absent t13 "Relay image digest:" 10 || true
  else
    bad "menu entry 'About' not reachable"
  fi

  # A real .env write must leave a timestamped backup next to the file
  send_settled t13 Home   # back to the top; goto_item only walks down
  if goto_item t13 ".env Editor"; then
    tmx send-keys -t t13 Enter
    wait_for t13 "Add variable"
    goto_item t13 "Add variable"
    tmx send-keys -t t13 Enter
    wait_for t13 "New key"
    tmx send-keys -t t13 -l "E2E_TEST_KEY"
    wait_for t13 "E2E_TEST_KEY"
    tmx send-keys -t t13 Enter
    wait_for t13 "New value"
    tmx send-keys -t t13 -l "42"
    wait_for t13 "42"
    tmx send-keys -t t13 Enter
    env_write_done() {
      grep -q "^E2E_TEST_KEY=42$" "$SB/.env" 2>/dev/null \
        && [[ -n "$(find "$SB" -maxdepth 1 -name '.env.bak.*' -print -quit 2>/dev/null)" ]]
    }
    if poll_until "$WAIT_T" env_write_done; then
      ok "env write leaves a timestamped backup and the new value"
    else
      bad "env write missing backup or value (backups=$(find "$SB" -maxdepth 1 -name '.env.bak.*' | wc -l), value=$(grep -c E2E_TEST_KEY "$SB/.env" 2>/dev/null))"
    fi
  else
    bad "menu entry '.env Editor' not reachable"
  fi
fi
kill_pane t13

# docs must mention the new keys and the restore path
if grep -q "Keyboard reference" "$ROOT_DIR/README.md" && grep -q "Backups and restore" "$ROOT_DIR/README.md"; then
  ok "README covers keyboard reference and backup restore"
else
  bad "README sections missing"
fi
if grep -q "## Unreleased" "$ROOT_DIR/CHANGELOG.md"; then
  ok "CHANGELOG has an Unreleased section for this pass"
else
  bad "CHANGELOG entry missing"
fi

# --- isolation proofs --------------------------------------------------------
# 1) no state-changing docker call reached the mock of any sandbox — except
#    the one a check provokes on purpose: the env write of check 13 makes the
#    TUI restart a running relay (down, then up), which the mock answers.
risky='(^| )(stop|start|up|down|run|rm|restart|pull|kill|create)( |$)'
risky_calls=0
for sb in "${SANDBOXES[@]}"; do
  [[ -f "$sb/.rig/calls.log" ]] || continue
  if [[ "$sb" == */sb-t13 ]]; then
    n="$(grep -E "$risky" "$sb/.rig/calls.log" | grep -cvE '(^| )(down|up)( |$)')"
    if grep -qE '(^| )down( |$)' "$sb/.rig/calls.log"; then
      ok "env write with a running relay triggers the restart path (down reached the mock, not docker)"
    else
      bad "env write did not trigger the restart path (no down in the mock log)"
    fi
  else
    n="$(grep -cE "$risky" "$sb/.rig/calls.log")"
  fi
  if [[ "$n" -gt 0 ]]; then
    say "  unexpected state-changing call(s) in $(basename "$sb"): $(grep -E "$risky" "$sb/.rig/calls.log" | head -3 | tr '\n' '|')"
  fi
  risky_calls=$((risky_calls + n))
done
if [[ "$risky_calls" -eq 0 ]]; then
  ok "no unexpected state-changing docker call reached the mock (${#SANDBOXES[@]} sandboxes)"
else
  bad "$risky_calls unexpected state-changing docker call(s) reached the mock"
fi
# 2) the real tree is exactly as it was
FP_AFTER="$(fingerprint)"
if [[ "$FP_BEFORE" == "$FP_AFTER" ]]; then
  ok "real repo untouched (.env, db/ + blossom/, git status fingerprints identical)"
else
  bad "real repo changed during the run"
fi

say ""
say "e2e-tui: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
