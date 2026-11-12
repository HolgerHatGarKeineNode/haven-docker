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
#   14. frame geometry (capture -N) at five sizes and after a resize
#   15. NO_COLOR; 16. restart after an .env change asks before it stops
#   17. TUI stderr stays empty through every view
#   18-21. data flows, settings editor, leftovers (P6)
#   22-25. the P6 security audit: pasted .env lines, empty Enter on a masked
#          value, crafted child output, Ctrl-C at the result box, cleanup with
#          a piped stdin, the restart after a saved setting
#
# Isolation (enforced here, not requested): every check runs in its OWN copy of
# the repository's tracked files under a temp dir, with .env.example as .env, a
# scripted mock docker forced to the front of PATH, a private tmux server
# (own socket, no user config) and a pinned TERM / LC_ALL. Nothing in the real
# working tree is read for writing; the rig proves that at the end by comparing
# fingerprints of the real .env and of db/ + blossom/ before and after.
#
# Stream content: only check 7 (producer restart), 5 and 6 (CPU, latency: the
# stream is part of the load) run against the endless counter stream. Every claim
# about WHAT the log panel shows (check 12) is made on a frozen stream, see there.
# Each section prints its wall time and how many polls ran into their bound.
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
STREAM_T=40                   # bound (s) for waits on the ENDLESS mock stream's progress (check 7): it
                              # makes 5 lines/s whatever the load, so COUNTER=40 needs 8 s of
                              # stream time, which a short WAIT_T override must not cut off
declare -A SBOF=()            # tmux session name -> its sandbox directory
SANDBOXES=()
TIMEOUT_LOG="$WORK/poll-timeouts.log"   # one line per poll_until that hit its bound
SEC_NAME=""
SEC_T0=0
SEC_TO0=0

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

# --- per-section wall time ----------------------------------------------------
# section <name> closes the previous section (prints its wall time and how many
# polls ran into their bound — in a green run that must be 0 for every section
# that does not wait for a negative on purpose) and opens the next one.
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
timeouts_so_far() { [[ -f "$TIMEOUT_LOG" ]] && wc -l < "$TIMEOUT_LOG" || echo 0; }
section_end() {
  [[ -n "$SEC_NAME" ]] || return 0
  local ms hits
  ms=$(( $(now_ms) - SEC_T0 ))
  hits=$(( $(timeouts_so_far) - SEC_TO0 ))
  say "TIME: $SEC_NAME: $((ms / 1000)).$((ms % 1000 / 100)) s, polls that hit their bound: $hits"
  if (( hits > 0 )); then
    tail -n "$hits" "$TIMEOUT_LOG" | sed 's/^/  bound hit: /' | cut -c1-140
  fi
  SEC_NAME=""
}
section() { section_end; SEC_NAME="$1"; SEC_T0="$(now_ms)"; SEC_TO0="$(timeouts_so_far)"; }
RUN_T0="$(now_ms)"

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
  else
    inner+=" && unset HAVEN_TUI_SYNC_FILE"   # the caller's environment must not leak the seam in
  fi
  inner+=" && $cmd"
  tmx new-session -d -x "$cols" -y "$lines" -s "$name" "bash -c $(printf '%q' "$inner")"
}

kill_pane() { tmx kill-session -t "$1" >/dev/null 2>&1 || true; }

# --- polling helpers --------------------------------------------------------

capture()   { tmx capture-pane -p -t "$1"; }
capture_n() { tmx capture-pane -p -N -t "$1"; }   # trailing blanks kept: columns stay true
pane_dead() { tmx list-panes -t "$1" -F '#{pane_dead}' 2>/dev/null | head -1; }

# poll_until <timeout_s> <command...> — true as soon as the command succeeds
poll_until() {
  local t="$1" deadline
  shift
  deadline=$(( $(date +%s%N) / 1000000 + t * 1000 ))
  while :; do
    "$@" && return 0
    if (( $(date +%s%N) / 1000000 >= deadline )); then
      # a poll that ran into its bound is a wait that was not a condition (or a
      # failed check); the file survives command substitutions, an array would not
      printf '%s\n' "$*" >> "$TIMEOUT_LOG"
      return 1
    fi
    sleep 0.05
  done
}

has_text() { local out; out="$(capture "$1")"; [[ "$out" == *"$2"* ]]; }
no_text()  { ! has_text "$1" "$2"; }
wait_for()    { poll_until "${3:-$WAIT_T}" has_text "$1" "$2"; }
wait_absent() { poll_until "${3:-$WAIT_T}" no_text "$1" "$2"; }

# right_cells <session> <screen-lines> — the log panel's content rows (4 .. lines-2) of the
# right pane, trimmed, empty cells left out, one per line. Pure bash: the left pane contains
# a "│" of its own, so the cell is what follows the LAST "│ " of the row.
right_cells() {
  local row cell
  while IFS= read -r row; do
    row="${row%│}"
    cell="${row##*│ }"
    cell="${cell%"${cell##*[! ]}"}"
    [[ -n "${cell// /}" ]] && printf '%s\n' "$cell"
  done < <(capture "$1" | sed -n "4,$(( $2 - 2 ))p")
}
cell_present() { right_cells "$1" "$2" | grep -qxF -- "$3"; }

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
section "1 too-small terminal"
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
section "2 resize with prompt"
new_sandbox t2
start_pane t2 120 40 "$SB" './haven tui'
if ! wait_for t2 "▸ s Start"; then
  bad "TUI did not reach the main view (startup)"
elif ! goto_item t2 "c Settings (.env)"; then
  bad "menu entry 'c Settings (.env)' not reachable"
else
  tmx send-keys -t t2 Enter                             # open env_list
  wait_for t2 "Add setting"
  goto_item t2 "Add setting"
  tmx send-keys -t t2 Enter                             # "Add setting" opens tui_prompt ("New key: ")
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
section "3 bracketed paste"
new_sandbox t3
start_pane t3 100 30 "$SB" './haven tui'
if ! wait_for t3 "Haven"; then
  bad "TUI did not start for the paste check"
else
  wait_for t3 "▸ s Start"
  alive_before="$(pane_dead t3)"
  tmx send-keys -t t3 -l $'\033[200~pasted-garbage\033[201~'
  # Barrier: keys are consumed in order, so once the Down below took effect the
  # paste has been fully handled.
  if goto_item t3 "t Start with Tor"; then
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
  # pane_dead prints 0 for a live pane and NOTHING once the session is gone (a
  # TUI that exited takes its window with it): "!= 1" would pass for a dead TUI.
  if [[ "$alive_before" == "0" && "$alive_after" == "0" ]] && tui_pid_found t3; then
    ok "TUI process still alive after bracketed paste"
  else
    bad "TUI process died on paste (pane_dead before='$alive_before' after='$alive_after')"
  fi
fi
kill_pane t3

# --- 4: die() visible after TUI cleanup --------------------------------------
section "4 die() visibility"
# Runs in a subshell so die()'s exit does not close the tmux window before
# the capture; sleep keeps the pane alive with the message on screen. The pane
# is put on the alternate screen first, like the real TUI: only there does a
# message printed BEFORE the cleanup's rmcup get swallowed (on the normal screen
# rmcup is a no-op, which made this check pass for any order).
new_sandbox t4
SYNC=0 start_pane t4 100 30 "$SB" '( source ./haven; TUI_ACTIVE=1; TUI_STTY_ORIG=$(stty -g); tput smcup; die boom-visible ); sleep 30'
wait_for t4 "boom-visible" || true
out="$(capture t4)"
if [[ "$out" == *"boom-visible"* && "$out" == *"ERROR"* ]]; then
  ok "die() message visible on the normal screen"
else
  bad "die() message swallowed (got: $(printf '%s' "$out" | tr -d '\n' | head -c 120))"
fi
kill_pane t4

# --- 5: idle CPU — absolute budget -------------------------------------------
section "5 idle CPU"
# The TUI's OWN utime+stime over an idle window must stay under a fixed number
# of ticks. (Until 2026-11-11 this compared against the 50 ms-poll baseline
# 753dab5; that claim was false once the tick fields were read correctly:
# 753dab5 +24, 84028fc +35, HEAD +36 ticks/20 s, so it is not asserted anymore.)
# Measured 2026-11-11: idle 35-40 ticks (6 runs), 54-63 under one busy loop per
# core (3 runs); a deliberately busy poll (read -t 0.005) 119-156 idle, 221
# loaded (7 runs). 90 is 1.4x over the loaded maximum and 1.3x under the busy
# minimum. It does NOT catch a return to the 50 ms poll (753dab5: 24 ticks).
IDLE_WINDOW_S=20
IDLE_BUDGET_TICKS=90   # at CLK_TCK=100 and a 20 s window: 90 ticks = 4.5 % of one core
measure_idle_cpu() { # <session> — echoes ticks over the idle window
  local pid t0 t1
  # warmed up = the log stream reached the panel
  wait_for "$1" "COUNTER=" || { echo ""; return 1; }
  poll_until "$WAIT_T" tui_pid_found "$1" || { echo ""; return 1; }
  pid="$(tui_pid "$1")"
  t0="$(cpu_ticks "$pid")" || { echo ""; return 1; }
  sleep "$IDLE_WINDOW_S"   # the measurement window itself
  t1="$(cpu_ticks "$pid")" || { echo ""; return 1; }   # fails if the TUI died in the window
  echo "$((t1 - t0))"
}

new_sandbox t5
SYNC=0 start_pane t5 100 30 "$SB" './haven tui'
ticks_idle="$(measure_idle_cpu t5)"
kill_pane t5

clk_tck="$(getconf CLK_TCK)"
if [[ -z "${ticks_idle:-}" ]]; then
  bad "idle CPU measurement failed (no ticks: TUI not found or died in the window)"
elif [[ "$clk_tck" != "100" ]]; then
  bad "idle CPU budget is calibrated for CLK_TCK=100, this host has $clk_tck"
elif (( ticks_idle < 1 )); then
  bad "idle CPU measurement is vacuous: 0 ticks in ${IDLE_WINDOW_S} s (wrong process?)"
elif (( ticks_idle <= IDLE_BUDGET_TICKS )); then
  ok "idle CPU within budget (${ticks_idle} ticks in ${IDLE_WINDOW_S} s, budget ${IDLE_BUDGET_TICKS})"
else
  bad "idle CPU over budget: ${ticks_idle} ticks in ${IDLE_WINDOW_S} s, budget ${IDLE_BUDGET_TICKS}"
fi

# --- 6: key latency below 300 ms ---------------------------------------------
section "6 key latency"
new_sandbox t6
: > "$SB/.rig/t6-start"   # files the TUI creates from here on are newer than this
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
# seam unset: the TUI must not write a counter, nor the temp file of one, anywhere:
# no file in the sandbox that is newer than the start marker (outside .rig, whose
# only legitimate writer is the mock docker) and none named sync*/*.tmp in .rig.
# (A mutant without the guard writes "./.tmp" — a name no sync* pattern matches.)
stray="$(
  find "$SB" -type f -newer "$SB/.rig/t6-start" ! -path "$SB/.rig/*" -print
  find "$SB/.rig" -type f \( -name 'sync*' -o -name '*.tmp' \) -print
)"
if [[ -z "$stray" ]]; then
  ok "HAVEN_TUI_SYNC_FILE unset: no render counter or temp file written"
else
  bad "files written although HAVEN_TUI_SYNC_FILE was unset: $(printf '%s' "$stray" | head -3 | tr '\n' ' ')"
fi

# --- 7: producer death — the panel restarts the stream -----------------------
section "7 producer death"
new_sandbox t7
start_pane t7 100 30 "$SB" './haven tui'
# the first lines (COUNTER=0) must have scrolled out of the panel, otherwise
# seeing COUNTER=0 after the kill would prove nothing
if ! wait_for t7 "COUNTER=40" "$STREAM_T"; then
  bad "mock log stream did not reach the panel"
elif cell_present t7 30 "MOCKLOG COUNTER=0"; then
  bad "COUNTER=0 still on screen before the kill — restart check would be vacuous"
else
  # only the producer of THIS sandbox's mock: its argv carries the sandbox path
  mock_pid="$(pgrep -f -- "$SB/tests/mock/docker compose.* logs" | head -1)"
  if [[ -z "$mock_pid" ]]; then
    bad "no mock producer process found to kill"
  else
    kill "$mock_pid" 2>/dev/null
    t0_ms=$(( $(date +%s%N) / 1000000 ))
    # Cannot be satisfied by coincidence: the stream counts up from 0 per producer,
    # the first producer is dead after the kill (no new line from it), and the
    # pre-check above showed COUNTER=0 is off the screen — so the whole-cell line
    # "MOCKLOG COUNTER=0" can only be drawn by a producer started AFTER the kill,
    # i.e. by the restart (a restarted buffer shows it for ~5 s, 5 lines/s).
    if poll_until "$WAIT_T" cell_present t7 30 "MOCKLOG COUNTER=0"; then
      ok "panel restarted the stream after producer death (fresh COUNTER=0 visible after $(( $(date +%s%N) / 1000000 - t0_ms )) ms)"
    else
      bad "panel did not refresh after producer death ($(capture t7 | grep -c COUNTER) counter lines)"
    fi
  fi
fi
kill_pane t7

# --- 8: navigation keys (P4) --------------------------------------------------
section "8 navigation"
new_sandbox t8
start_pane t8 100 30 "$SB" './haven tui'
if ! wait_for t8 "▸ s Start"; then
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
  if goto_item t8 "x Stop"; then
    send_settled t8 k;   nav_case "t Start with Tor" "k"
    send_settled t8 j;   nav_case "x Stop" "j"
    send_settled t8 G;   nav_case "q Quit" "G"
    send_settled t8 g;   nav_case "s Start" "g"
    send_settled t8 End; nav_case "q Quit" "End"
    send_settled t8 Home; nav_case "s Start" "Home"
    # group names are skipped: Down from the last Relay entry lands on the first
    # Data entry, Up from there comes back (the "Data" row is never selected)
    if goto_item t8 "r Restart"; then
      send_settled t8 j;  nav_case "b Back up now" "j across the Data group name"
      send_settled t8 k;  nav_case "r Restart" "k across the Data group name"
    else
      bad "navigation: menu entry 'r Restart' not reachable"
    fi
  else
    bad "navigation: menu entry 'x Stop' not reachable"
  fi
fi
kill_pane t8

# NOTE: the digit shortcuts are proven at unit level (tests/haven-input.bats,
# "digit shortcuts select the nth entry directly", and tests/haven-menu.bats for
# the grouped main menu, where digits count entries, not group names); an e2e
# case for them can only be index-based and is not kept here. The letter
# shortcuts are proven against Enter at unit level (tests/haven-menu.bats). PgUp/PgDn paged the menu until P4;
# P5 assigns them to the log scrollback — see check 12.

prompt_has_q() { capture t9 | grep 'New key' | grep -q 'Q'; }

# prompt_cancelled <session> <label> — Escape at an open prompt, then PROOF that it
# closed: once the Escape is settled (two render passes), the label row is gone and
# the terminal row the prompt used shows exactly what it showed before the prompt
# opened (the menu repainted it), with no further key. Until P5 a closed prompt left
# its row painted until the next full redraw, and this helper had to send "j" to
# provoke that redraw. The row text before the prompt is taken by prompt_open.
prompt_cancelled() {
  local s="$1" label="$2"
  send_settled "$s" Escape || return 1
  # polled: the end state only — the stale row of the old code is never repainted
  # by a later pass (spinner passes draw the right pane only), so waiting cannot
  # turn it into a pass
  poll_until "$WAIT_T" prompt_row_restored "$s" "$label"
}
# prompt_open <session> <expected label> — Enter on the selected entry, remembering
# the terminal row the prompt is about to use (row TUI_LINES-3, 1-based LINES-2)
PROMPT_ROW_BEFORE=""
prompt_open() {
  local s="$1" label="$2" lines
  lines="$(tmx display -p -t "$s" '#{pane_height}')"
  # the list may still be drawing when its first entry shows: two finished passes
  settle_after "$s" "$(sync_n "$s")"
  PROMPT_ROW_BEFORE="$(capture_n "$s" | sed -n "$((lines - 2))p")"
  tmx send-keys -t "$s" Enter
  wait_for "$s" "$label"
}
prompt_row_restored() {
  local s="$1" label="$2" lines
  lines="$(tmx display -p -t "$s" '#{pane_height}')"
  no_text "$s" "$label" && [[ "$(left_cell "$(capture_n "$s" | sed -n "$((lines - 2))p")")" == "$(left_cell "$PROMPT_ROW_BEFORE")" ]]
}
# prompt_cell_is <session> <label> <text> — the input cell of the open prompt <label>
# (between the label and the pane border, trimmed) equals <text>
prompt_cell_is() {
  local row cell
  row="$(capture "$1" | grep -m1 -F -- "$2")" || return 1
  cell="${row#*"$2"}"
  cell="${cell%%│*}"
  cell="${cell#"${cell%%[! ]*}"}"
  cell="${cell%"${cell##*[! ]}"}"
  [[ "$cell" == "$3" ]]
}
# left_cell <row> — the left pane's part of a screen row (between the first two │);
# the right pane streams and is no part of the comparison
left_cell() { local r="${1#│}"; printf '%s' "${r%%│*}"; }

# --- 9+10: prompt editor — paste, Ctrl-U, Ctrl-W (P4) -------------------------
section "9+10 prompt editor"
# 160 cols so the 30-char paste fits the prompt's input budget.
new_sandbox t9
env_hash_t9="$(sha256sum "$SB/.env" | cut -d' ' -f1)"
start_pane t9 160 30 "$SB" './haven tui'
if ! wait_for t9 "▸ s Start"; then
  bad "TUI did not start for the prompt editor check"
elif ! goto_item t9 "c Settings (.env)"; then
  bad "menu entry 'c Settings (.env)' not reachable"
else
  tmx send-keys -t t9 Enter
  wait_for t9 "Add setting"
  goto_item t9 "Add setting"
  if ! prompt_open t9 "New key"; then  # "Add setting" opens the "New key: " prompt
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
    # the whole input cell, not a substring test: "foo" stays, "bar" and the blank in
    # front of it (the implementation removes both) are gone, the marker follows
    # directly — "Z9fooQ" and nothing else. A Ctrl-W that deleted one character
    # would leave "Z9foo baQ"; the cell is cut at the pane border like the filter prompt's.
    row="$(capture t9 | grep -m1 'New key: ')"
    cell="${row#*New key: }"
    cell="${cell%%│*}"
    cell="${cell#"${cell%%[! ]*}"}"
    cell="${cell%"${cell##*[! ]}"}"
    if [[ "$cell" == "Z9fooQ" ]]; then
      ok "prompt: Ctrl-W deletes the word before the cursor"
    else
      bad "prompt: Ctrl-W deletes the word before the cursor (input cell is '$cell', want 'Z9fooQ')"
    fi
    # cancel the prompt — nothing must be written to .env
    if prompt_cancelled t9 "New key"; then
      ok "Escape closes the key prompt and clears its row (the menu row is back, no further key)"
    else
      bad "Escape did not close the key prompt ($(capture t9 | grep -m1 'New key' | head -c 60))"
    fi
    if [[ "$(sha256sum "$SB/.env" | cut -d' ' -f1)" == "$env_hash_t9" ]]; then
      ok "cancelled prompt leaves .env byte-identical"
    else
      bad "cancelled prompt changed .env"
    fi
  fi
fi
kill_pane t9

# --- 11: masking, reveal, inline validation (P4) ------------------------------
section "11 masking and validation"
# A small .env of its own keeps the list on one screen (no scrolling to find
# the entry); it lives in the sandbox like everything else.
new_sandbox t11
printf 'RELAY_URL="relay.example.org"\nTEST_SECRET_KEY=abcdefgh1234\n' > "$SB/.env"
mkdir -p "$SB/db/private" && printf 'fake\n' > "$SB/db/private/MANIFEST"
env_hash_t11="$(sha256sum "$SB/.env" | cut -d' ' -f1)"
start_pane t11 100 30 "$SB" './haven tui'
if ! wait_for t11 "▸ s Start"; then
  bad "TUI did not start for the masking check"
elif ! goto_item t11 "c Settings (.env)"; then
  bad "menu entry 'c Settings (.env)' not reachable"
else
  tmx send-keys -t t11 Enter
  wait_for t11 "test secret key"
  out="$(capture t11)"
  # the row's value cell (right-aligned after the label) is exactly the mask: a
  # mask that only APPENDS something (…1234abcd…) must not pass as "…1234"
  row="$(left_cell "$(printf '%s\n' "$out" | grep -m1 'test secret key')")"
  row="${row%"${row##*[! ]}"}"
  cell="${row##* }"
  if [[ "$cell" == "…1234" && "$out" != *"abcdefgh1234"* ]]; then
    ok "env list masks sensitive values (…1234)"
  else
    bad "env list does not mask (value cell '$cell')"
  fi
  # open the key, then reveal
  if goto_item t11 "test secret key"; then
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
  wait_for t11 "Add setting"
  goto_item t11 "Add setting"
  prompt_open t11 "New key"
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
  if prompt_cancelled t11 "New value"; then
    ok "Escape closes the value prompt and clears its row"
  else
    bad "Escape did not close the value prompt ($(capture t11 | grep -m1 'New value' | head -c 60))"
  fi
  # DB_ENGINE away from the engine of the data in db/ is refused at the prompt
  # and names the db-switch that moves the data (the sandbox db/ holds badger)
  wait_for t11 "Add setting"
  send_settled t11 Home   # back to the top; goto_item only walks down
  goto_item t11 "Add setting"
  prompt_open t11 "New key"
  tmx send-keys -t t11 -l "DB_ENGINE"
  wait_for t11 "DB_ENGINE"
  tmx send-keys -t t11 Enter
  wait_for t11 "New value"
  tmx send-keys -t t11 -l "lmdb"
  wait_for t11 "lmdb"
  tmx send-keys -t t11 Enter
  # the error wraps onto the rows above the prompt: judged on the joined left cells
  t11_refused() {
    local r all=""
    while IFS= read -r r; do all+="$(left_cell "$r") "; done < <(capture t11 | sed -n '4,28p')
    all="$(tr -s ' ' <<<"$all")"
    [[ "$all" == *"use ./haven db-switch lmdb"* ]]
  }
  if poll_until "$WAIT_T" t11_refused; then
    ok "DB_ENGINE flip against the data on disk is refused inline, naming db-switch lmdb"
  else
    bad "DB_ENGINE flip not refused inline ($(capture t11 | tr '\n' '|' | head -c 200))"
  fi
  if prompt_cancelled t11 "New value"; then
    ok "Escape closes the refused DB_ENGINE prompt"
  else
    bad "Escape did not close the refused DB_ENGINE prompt"
  fi
fi
kill_pane t11
if [[ "$(sha256sum "$SB/.env" | cut -d' ' -f1)" == "$env_hash_t11" ]]; then
  ok ".env untouched by the cancelled add"
else
  bad ".env was modified by the cancelled add"
fi

# --- 12: panel QoL — scrollback, filter, status view (P5) ---------------------
section "12 scrollback, filter, status"
# Everything this check says about stream CONTENT is said about a FROZEN stream:
# the mock emits exactly STREAM_N lines (MOCK_LOG_COUNT) and then stays attached
# and silent, so the screen can be waited for ONCE (the complete expected tail is
# on it) and read afterwards without a later stream position being able to
# satisfy or spoil anything. Counts and line sets are compared whole: the cells
# of the right pane, trimmed, one per row, against the full expected list — not
# a substring, not "contains", not a poll that a different state could satisfy.
# After every key that defines the view, settle_after (two finished render
# passes) comes BEFORE the one read.
STREAM_N=120                 # lines of the finite stream: COUNTER=0 .. 119
T12_LINES=34
T12_H=$((T12_LINES - 5))     # content rows of the log panel (haven-render.bats pins 29 for 120x34)

counters_text() { # <from> <to> — the stream's lines from..to
  local n
  for ((n = $1; n <= $2; n++)); do printf 'MOCKLOG COUNTER=%d\n' "$n"; done
}
t12_cells() { right_cells t12 "$T12_LINES"; }
t12_tail_text() { counters_text $((STREAM_N - T12_H)) $((STREAM_N - 1)); }
# the complete expected live tail is on screen: only the final state of the
# frozen stream has it, an earlier stream position does not
t12_tail_shown() { [[ "$(t12_cells)" == "$(t12_tail_text)" ]]; }

# The filter prompt row: its cell (between the label and the pane border) has to
# equal <text> — "" is "open and empty". (Until P5 a submitted prompt left its row
# painted, so the cell, not the bare label, had to tell "open" from "stale"; since
# P5 the row is cleared on submit, which t12_filter's caller checks.) The row shares
# its terminal row with the right pane, which is why this reads the cell and not
# the row.
filter_prompt_is() { # <text>
  local row cell
  row="$(capture t12 | grep -m1 'Filter logs:')" || return 1
  cell="${row#*Filter logs:}"
  cell="${cell%%│*}"
  cell="${cell#"${cell%%[! ]*}"}"
  cell="${cell%"${cell##*[! ]}"}"
  [[ "$cell" == "$1" ]]
}
# t12_filter <text> — open the filter prompt, type, submit, and wait for the render
# that applies it (two passes after the Enter)
t12_filter() {
  local n0
  PROMPT_ROW_BEFORE="$(capture_n t12 | sed -n "$((T12_LINES - 2))p")"
  tmx send-keys -t t12 /
  poll_until "$WAIT_T" filter_prompt_is "" || return 1
  if [[ -n "$1" ]]; then
    tmx send-keys -t t12 -l "$1"
    poll_until "$WAIT_T" filter_prompt_is "$1" || return 1
  fi
  n0="$(sync_n t12)"
  tmx send-keys -t t12 Enter
  settle_after t12 "$n0"
}

new_sandbox t12
# distinct, known sizes for the status view: db/ gets 3 MB of filler, blossom/ stays
# as tracked, so a swapped or missing du shows up in the numbers
head -c 3000000 /dev/zero > "$SB/db/filler"
du_db="$(du -sh "$SB/db" | awk '{print $1}')"
du_blossom="$(du -sh "$SB/blossom" | awk '{print $1}')"
start_pane t12 120 "$T12_LINES" "$SB" "MOCK_LOG_COUNT=$STREAM_N ./haven tui"
if ! poll_until "$STREAM_T" t12_tail_shown; then
  bad "frozen stream did not settle: the panel never showed exactly COUNTER=$((STREAM_N - T12_H))..$((STREAM_N - 1)) (rows: $(t12_cells | wc -l), last: $(t12_cells | tail -1))"
else
  ok "frozen stream settled: the panel shows exactly the newest $T12_H lines (COUNTER=$((STREAM_N - T12_H))..$((STREAM_N - 1)))"

  # --- scrollback: one page back, the top, and the way down again
  page=$((T12_H - 1))
  lo=$((STREAM_N - T12_H - page))
  send_settled t12 PgUp
  if has_text t12 "│ Paused"; then
    ok "PgUp pauses the panel and names it in the panel title"
  else
    bad "PgUp did not show the pause banner"
  fi
  if [[ "$(t12_cells)" == "$(counters_text "$lo" $((lo + T12_H - 1)))" ]]; then
    ok "PgUp pages back exactly one page (COUNTER=$lo..$((lo + T12_H - 1)))"
  else
    bad "PgUp page is not COUNTER=$lo..$((lo + T12_H - 1)) (rows: $(t12_cells | head -1) .. $(t12_cells | tail -1), $(t12_cells | wc -l) rows)"
  fi
  # four more pages: the 4th already reaches the top, the 5th must not scroll past it
  for _ in 1 2 3 4; do send_settled t12 PgUp; done
  if [[ "$(t12_cells)" == "$(counters_text 0 $((T12_H - 1)))" ]]; then
    ok "PgUp at the top stops at the oldest line (COUNTER=0..$((T12_H - 1)))"
  else
    bad "top of the scrollback is not COUNTER=0..$((T12_H - 1)) (rows: $(t12_cells | head -1) .. $(t12_cells | tail -1), $(t12_cells | wc -l) rows)"
  fi
  # the way back: from the clamped top four pages bring the live end back — had the
  # scroll position overshot the top, four PgDn would still be paused
  for _ in 1 2 3 4; do send_settled t12 PgDn; done
  if has_text t12 "Paused"; then
    bad "PgDn did not resume the live view after four pages down from the top"
  elif t12_tail_shown; then
    ok "PgDn resumes the live view (exactly COUNTER=$((STREAM_N - T12_H))..$((STREAM_N - 1)) again)"
  else
    bad "after PgDn the live tail is not restored (rows: $(t12_cells | head -1) .. $(t12_cells | tail -1))"
  fi

  # --- live filter via slash: every line of the finite stream containing a 9
  want_lines="$(seq 0 $((STREAM_N - 1)) | grep -F 9 | sed 's/^/MOCKLOG COUNTER=/')"
  want_n="$(printf '%s\n' "$want_lines" | wc -l)"
  if [[ "$want_n" != "21" ]]; then
    bad "filter fixture changed: expected 21 lines containing a 9 in the stream, found $want_n"
  elif ! t12_filter "9"; then
    bad "filter prompt did not open, take the text or apply it (prompt row: $(capture t12 | grep -m1 'Filter logs:' | head -c 80))"
  else
    # submitted: the prompt row is cleared and the menu row under it is back, with
    # no further key (two render passes after the Enter have run)
    if poll_until "$WAIT_T" prompt_row_restored t12 "Filter logs:"; then
      ok "a submitted prompt clears its row (the menu row is back)"
    else
      bad "a submitted prompt left its row painted ($(capture_n t12 | sed -n "$((T12_LINES - 2))p" | head -c 60))"
    fi
    cells="$(t12_cells)"
    banner="$(printf '%s\n' "$cells" | head -1)"
    shown="$(printf '%s\n' "$cells" | tail -n +2)"
    if [[ "$banner" == "21 matching lines" ]]; then
      ok "slash search shows the exact match count (21 matching lines)"
    else
      bad "slash search banner is not '21 matching lines' (got: ${banner:0:60})"
    fi
    # kept: the stream's oldest (9) and newest (119) matches and everything between
    missing="$(LC_ALL=C comm -13 <(printf '%s\n' "$shown" | LC_ALL=C sort) <(printf '%s\n' "$want_lines" | LC_ALL=C sort) | tr '\n' ',')"
    if [[ -z "$missing" ]]; then
      ok "filter keeps every matching line, oldest (COUNTER=9) and newest (COUNTER=119) included"
    else
      bad "filter lost matching lines: ${missing:0:120}"
    fi
    # hidden: nothing but matching lines, none twice
    stray="$(LC_ALL=C comm -23 <(printf '%s\n' "$shown" | LC_ALL=C sort) <(printf '%s\n' "$want_lines" | LC_ALL=C sort) | tr '\n' ',')"
    dups="$(printf '%s\n' "$shown" | LC_ALL=C sort | uniq -d | tr '\n' ',')"
    if [[ -z "$stray" && -z "$dups" ]]; then
      ok "filter hides every non-matching line"
    else
      bad "filter shows lines it should not (stray: ${stray:0:100} duplicated: ${dups:0:60})"
    fi
    if [[ "$shown" == "$want_lines" ]]; then
      ok "filtered lines come in stream order, the first one right under the banner"
    else
      bad "filtered lines are not exactly the expected 21 in stream order (first: $(printf '%s\n' "$shown" | head -1), $(printf '%s\n' "$shown" | wc -l) rows)"
    fi

    # one match: the banner AND that line — the hit-count row must not eat the first line
    if ! t12_filter "COUNTER=77"; then
      bad "second filter prompt did not open or apply"
    elif [[ "$(t12_cells)" == $'1 matching line\nMOCKLOG COUNTER=77' ]]; then
      ok "one match: the banner and that one line are drawn (COUNTER=77)"
    else
      bad "one match is not banner + COUNTER=77 (got: $(t12_cells | tr '\n' '|' | head -c 120))"
    fi
    # empty input clears: banner gone, live tail back (after the settle, one read)
    if ! t12_filter ""; then
      bad "clearing prompt did not open or apply"
    elif [[ "$(t12_cells)" == "$(t12_tail_text)" ]]; then
      ok "empty filter input clears the search (banner gone, live tail restored)"
    else
      bad "empty filter did not clear the search (rows: $(t12_cells | head -1) .. $(t12_cells | tail -1))"
    fi
  fi

  # status panel via Tab
  tmx send-keys -t t12 Tab
  wait_for t12 "Last backup" || true
  out="$(capture t12)"
  if [[ "$out" == *"│ Status "* && "$out" == *"running"* ]]; then
    ok "Tab switches to the status view (title + running container)"
  else
    bad "status view missing (title/running)"
  fi
  if [[ "$out" == *"haven-relay: running, up 2 hours"* && "$out" == *"haven-tor: stopped"* ]]; then
    ok "status lists container states and uptime"
  else
    bad "container states missing in the status view"
  fi
  if [[ "$out" == *"Image        "*", sha256:abcdef123456"* ]]; then
    ok "status shows the short image digest"
  else
    bad "image digest missing in the status view"
  fi
  if [[ "$du_db" == "$du_blossom" ]]; then
    bad "du check has no resolving power: db/ and blossom/ both measure $du_db"
  elif [[ "$out" == *", db/ $du_db "* && "$out" == *"Media        blossom/ $du_blossom "* ]]; then
    ok "status shows du -sh for db/ and blossom/ (db/ $du_db, blossom/ $du_blossom)"
  else
    bad "directory sizes wrong or missing in the status view (want db/ $du_db blossom/ $du_blossom; got: $(printf '%s' "$out" | grep -o '\(db\|blossom\)/ [^ ]*' | tr '\n' ' '))"
  fi
  send_settled t12 Tab
  if t12_tail_shown; then
    ok "Tab switches back to the log view (the frozen tail is drawn again)"
  else
    bad "Tab back did not restore the log view (rows: $(t12_cells | head -1) .. $(t12_cells | tail -1))"
  fi
fi
if [[ "$(sync_n t12)" -gt 0 ]]; then
  ok "HAVEN_TUI_SYNC_FILE set: render counter advanced ($(sync_n t12) passes)"
else
  bad "render counter did not advance with HAVEN_TUI_SYNC_FILE set"
fi
kill_pane t12

# --- 13: P6 — about screen, timestamped backup on write, docs ---------------
section "13 about screen, env backup"
new_sandbox t13
# The sandbox holds the TRACKED files only; the four <name>.json files the relay mounts
# are untracked and normally exist on a machine that ran haven before. Without them the
# restart asks one "Missing X.json. Copy from X.example.json now?" dialog per file and
# WAITS for an answer (since P5 before the stop; check 16 covers that path). This check
# is about the restart sequence alone: seed them, as on a machine that has run haven.
for example in "$SB"/*.example.json; do
  cp "$example" "${example/.example.json/.json}"
done
# What the restart path really sends to docker (plain mode: no haven-tor container
# runs), read from the product and a kept calls.log: stop_services -> `down
# --remove-orphans`, start_services -> `up -d --build` (BUILD_IMAGES=1), then `ps` and
# the read-only drift probe (`run ... --entrypoint cat relay /app/.env.example.upstream`).
T13_DOWN="compose -f $SB/docker-compose.yml down --remove-orphans"
T13_UP="compose -f $SB/docker-compose.yml up -d --build"
T13_DRIFT="compose -f $SB/docker-compose.yml run --rm --no-deps -T --entrypoint cat relay /app/.env.example.upstream"
# The calls a sandbox's mock may see are an ALLOWLIST: a call is fine when it is read-only
# (the verbs info, version, ps, inspect, logs — `docker`, or `docker compose -f
# <sandbox>/docker-compose[.tor].yml` for ps/logs) or when it is one of the exact lines the
# check in question expects. Everything else is unexpected, whatever its verb: a denylist of
# verbs (stop|up|down|…) let `system prune -af` through between down and up.
# The sandbox path is rewritten to SB/ before matching, so the shapes are exact.
READONLY_CALL='^(info|version|ps( .*)?|inspect( .*)?|logs( .*)?|compose version|compose -f SB/docker-compose(\.tor)?\.yml (ps|logs)( .*)?)$'
unexpected_calls() { # <sandbox> [<exact allowed line>…] — the calls.log lines that are neither, in order
  local sb="$1" line x
  shift
  [[ -f "$sb/.rig/calls.log" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    for x in "$@"; do [[ "$line" == "$x" ]] && continue 2; done
    [[ "${line//"$sb/"/SB/}" =~ $READONLY_CALL ]] && continue
    printf '%s\n' "$line"
  done < "$sb/.rig/calls.log"
}
start_pane t13 120 30 "$SB" './haven tui'
if ! wait_for t13 "▸ s Start"; then
  bad "TUI did not start for the P6 checks"
else
  if goto_item t13 "a About"; then
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
    bad "menu entry 'a About' not reachable"
  fi

  # A real .env write must leave a timestamped backup next to the file
  send_settled t13 Home   # back to the top; goto_item only walks down
  if goto_item t13 "c Settings (.env)"; then
    tmx send-keys -t t13 Enter
    wait_for t13 "Add setting"
    goto_item t13 "Add setting"
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
    # The restart (down, then up) follows the write in the TUI. Killing the pane
    # right after the write races it, and the isolation proof below reads the
    # mock's call log — so wait until the restart has reached the mock: the exact
    # `up` line, then two render passes (the handler is synchronous, the main loop
    # only renders once it has returned, so the rest of start_services is done).
    restart_reached() { grep -qxF -- "$T13_UP" "$SB/.rig/calls.log" 2>/dev/null; }
    if poll_until "$WAIT_T" restart_reached; then
      n0="$(sync_n t13)"
      settle_after t13 "$n0"
    fi
    got="$(unexpected_calls "$SB" "$T13_DRIFT")"
    if [[ "$got" == "$T13_DOWN"$'\n'"$T13_UP" ]]; then
      ok "env write with a running relay restarts exactly: down --remove-orphans, then up -d --build"
    else
      bad "env write with a running relay restarts exactly: down --remove-orphans, then up -d --build (got: $(printf '%s' "$got" | sed "s# -f $SB/# -f SB/#" | tr '\n' '|' | head -c 200))"
    fi
  else
    bad "menu entry 'c Settings (.env)' not reachable"
  fi
fi
kill_pane t13

# --- 14: frame geometry as tmux draws it (P5) ---------------------------------
section "14 frame geometry"
# Layer 2 of the geometry proof (layer 1: tests/haven-geometry.bats). The captured
# screen (`capture-pane -p -N`: without -N trailing blanks are dropped and the
# widths are wrong) is replayed through tests/term-emu.py: row 1 ends with │ at
# column COLS-1, row 2 starts with ├, and ┬, the title-row │, ┼ and ┴ share one
# column; nothing is wider than COLS. Every view that draws the title row, at five
# sizes, and once after a resize.
frame_report() { capture_n "$1" | sed 's/$/\r/' | python3 -I "$ROOT_DIR/tests/term-emu.py" "$2" "$3" frame; }
frame_right() { # <session> <cols> <lines>
  local rep a b c d
  rep="$(frame_report "$1" "$2" "$3")"
  grep -qx 'overflow 0' <<<"$rep" || return 1
  grep -qx "end 1 $(($2 - 1))" <<<"$rep" || return 1
  grep -qx 'last 1 │' <<<"$rep" || return 1
  grep -qx 'first 2 ├' <<<"$rep" || return 1
  read -r _ a b c d < <(grep '^junction' <<<"$rep")
  [[ "$a" -gt 0 && "$a" == "$b" && "$a" == "$c" && "$a" == "$d" ]]
}
geometry_case() { # <session> <cols> <lines> <view>
  if poll_until "$WAIT_T" frame_right "$1" "$2" "$3"; then
    ok "geometry ${2}x${3} $4: row 1 ends with │ at column $(($2 - 1)), row 2 starts with ├, junctions share a column"
  else
    bad "geometry ${2}x${3} $4: $(frame_report "$1" "$2" "$3" | grep -E '^(overflow|junction|end 1 |last 1 |first 2 )' | tr '\n' ' ')"
  fi
}
# left_rows <session> <from> <to> — the left pane's cells of screen rows from..to (1-based)
left_rows() { capture_n "$1" | sed -n "$2,$3p" | while IFS= read -r r; do left_cell "$r"; echo; done; }
# geometry_walk <session> <cols> <lines> — main, settings, access lists, status, log filter
geometry_walk() {
  local s="$1" c="$2" l="$3"
  geometry_case "$s" "$c" "$l" "main"
  send_settled "$s" c
  if wait_for "$s" "Add setting"; then
    geometry_case "$s" "$c" "$l" "settings"
    if [[ "$c" == 80 ]]; then
      if [[ "$(capture "$s" | sed -n 2p)" == *"Settings"* ]]; then
        ok "after opening Settings row 1 names it ($(capture "$s" | sed -n 2p | cut -c1-30))"
      else
        bad "row 1 does not name Settings ($(capture "$s" | sed -n 2p | cut -c1-40))"
      fi
    fi
  else
    bad "geometry ${c}x${l}: settings did not open"
  fi
  send_settled "$s" Escape
  wait_for "$s" "▸ s Start"
  send_settled "$s" l
  if wait_for "$s" "Haven / Access lists"; then
    geometry_case "$s" "$c" "$l" "access lists"
  else
    bad "geometry ${c}x${l}: access lists did not open"
  fi
  send_settled "$s" Escape
  wait_for "$s" "▸ s Start"
  send_settled "$s" Tab
  if wait_for "$s" "│ Status "; then
    geometry_case "$s" "$c" "$l" "status"
  else
    bad "geometry ${c}x${l}: status view did not open"
  fi
  send_settled "$s" Tab
  tmx send-keys -t "$s" /
  wait_for "$s" "Filter logs:"
  tmx send-keys -t "$s" -l "=1"
  poll_until "$WAIT_T" prompt_cell_is "$s" "Filter logs:" "=1"
  tmx send-keys -t "$s" Enter
  if wait_for "$s" "matching line"; then
    geometry_case "$s" "$c" "$l" "log filter"
  else
    bad "geometry ${c}x${l}: the log filter did not apply"
  fi
}

for size in 66x20 80x24 100x24 120x30 160x40; do
  c="${size%x*}" l="${size#*x}" s="t14_$c"
  new_sandbox "t14-$c"
  start_pane "$s" "$c" "$l" "$SB" "MOCK_LOG_COUNT=40 ./haven tui"
  if ! wait_for "$s" "▸ s Start"; then
    bad "geometry ${size}: TUI did not reach the main view"
    kill_pane "$s"
    continue
  fi
  if [[ "$c" == 80 ]]; then
    # rows 1-4 (1-based) hold "Haven" once: row 2 names the view, the menu body has
    # no breadcrumb and no title row of its own
    top="$(capture "$s" | sed -n '1,4p')"
    if [[ "$(grep -o Haven <<<"$top" | wc -l)" -eq 1 ]]; then
      ok "rows 1-4 of the main view contain Haven once"
    else
      bad "rows 1-4 of the main view contain Haven $(grep -o Haven <<<"$top" | wc -l) times"
    fi
    # the relay state behind "Relay" at 80 columns: whole words only, no ellipsis
    state="$(left_rows "$s" 4 4)"
    if [[ "$state" == " Relay  "*"●"* || "$state" == " Relay  "*"○"* ]] && [[ "$state" != *"..."* && "$state" != *"…"* ]]; then
      ok "the relay state at 80 columns is not cut ($(sed 's/ *$//' <<<"$state"))"
    else
      bad "the relay state at 80 columns is cut or missing ('$state')"
    fi
    # no menu label is cut at 80 columns, and Help / About / Quit stand apart
    # from Configure: the row above "? Help" is blank
    body="$(left_rows "$s" 4 22)"
    if ! grep -qE '\.\.\.|…' <<<"$body" && [[ "$(grep -B1 '? Help' <<<"$body" | head -1 | tr -d ' ')" == "" ]]; then
      ok "no menu label is cut at 80x24 and a blank row sets Help / About / Quit apart"
    else
      bad "a menu label is cut at 80x24 or Help is not set apart ($(tr '\n' '|' <<<"$body" | head -c 200))"
    fi
    # the whole menu on one screen: the last entry is drawn, nothing scrolled
    if has_text "$s" "q Quit" && has_text "$s" "Relay" && has_text "$s" "s Start"; then
      ok "all 15 entries and the group names are visible at 80x24 (first and last drawn)"
    else
      bad "the main menu does not fit 80x24"
    fi
  fi
  geometry_walk "$s" "$c" "$l"
  if [[ "$c" == 120 ]]; then
    tmx resize-window -t "$s" -x 100 -y 24
    geometry_case "$s" 100 24 "log filter, after a resize from 120x30"
  fi
  kill_pane "$s"
done

# --- 15: NO_COLOR (P5) ---------------------------------------------------------
section "15 NO_COLOR"
# colour_sgr — the colour parameters (30-38, 40-48, 90-97, 100-107) in the SGR
# sequences on stdin, space separated; empty when there are none
colour_sgr() {
  python3 -I -c '
import re, sys
found = set()
for m in re.finditer(r"\x1b\[([0-9;:]*)m", sys.stdin.read()):
    for p in re.split("[;:]", m.group(1)):
        if p and (30 <= int(p) <= 38 or 40 <= int(p) <= 48 or 90 <= int(p) <= 97 or 100 <= int(p) <= 107):
            found.add(int(p))
print(" ".join(str(n) for n in sorted(found)))'
}
new_sandbox t15
start_pane t15 80 24 "$SB" 'NO_COLOR=1 MOCK_LOG_COUNT=30 ./haven tui'
new_sandbox t15c
start_pane t15c 80 24 "$SB" 'env -u NO_COLOR MOCK_LOG_COUNT=30 ./haven tui'
if wait_for t15 "▸ s Start" && wait_for t15 "COUNTER=29"; then
  sgr="$(tmx capture-pane -p -e -t t15 | colour_sgr)"
  if [[ -z "$sgr" ]]; then
    ok "NO_COLOR=1: the main view holds no colour SGR code"
  else
    bad "NO_COLOR=1: colour SGR codes on screen: $sgr"
  fi
  sel_row="$(tmx capture-pane -p -e -t t15 | grep -m1 '▸ s Start')"
  if [[ -n "$sel_row" && "$sel_row" =~ $'\e'\[([0-9]+\;)*7(\;[0-9]+)*m ]]; then
    ok "NO_COLOR=1: the selected row shows ▸ in reverse video"
  else
    bad "NO_COLOR=1: the selected row lacks ▸ or reverse video ($(printf '%q' "${sel_row:0:60}"))"
  fi
else
  bad "NO_COLOR=1: TUI did not reach the main view"
fi
if wait_for t15c "▸ s Start" && wait_for t15c "COUNTER=29"; then
  sgr="$(tmx capture-pane -p -e -t t15c | colour_sgr)"
  if [[ -n "$sgr" ]]; then
    ok "control without NO_COLOR: colour SGR codes found ($sgr)"
  else
    bad "control without NO_COLOR: no colour codes — the NO_COLOR check has no resolving power"
  fi
else
  bad "control without NO_COLOR: TUI did not reach the main view"
fi
kill_pane t15
kill_pane t15c

# --- 16: restart after an .env change asks its dialogs before the stop (P5) -----
section "16 restart dialogs before stop"
# The sandbox has no <name>.json (untracked files are not copied): the start half
# of the restart asks one "Missing X.json" dialog per file. They must come BEFORE
# the relay is stopped, so an unanswered dialog never leaves it down. The dialog is
# drawn from inside the restart handler, synchronously: once it is on screen,
# every docker call before it is in calls.log.
new_sandbox t16
T16_DOWN="compose -f $SB/docker-compose.yml down --remove-orphans"
T16_UP="compose -f $SB/docker-compose.yml up -d --build"
T16_DRIFT="compose -f $SB/docker-compose.yml run --rm --no-deps -T --entrypoint cat relay /app/.env.example.upstream"
start_pane t16 120 30 "$SB" 'MOCK_LOG_COUNT=10 ./haven tui'
if ! wait_for t16 "▸ s Start"; then
  bad "TUI did not start for the restart dialog check"
else
  send_settled t16 c
  wait_for t16 "Add setting"
  goto_item t16 "Add setting"
  prompt_open t16 "New key"
  tmx send-keys -t t16 -l "E2E_RESTART_KEY"
  poll_until "$WAIT_T" prompt_cell_is t16 "New key:" "E2E_RESTART_KEY"
  tmx send-keys -t t16 Enter
  wait_for t16 "New value"
  tmx send-keys -t t16 -l "7"
  poll_until "$WAIT_T" prompt_cell_is t16 "New value:" "7"
  tmx send-keys -t t16 Enter
  if wait_for t16 "Missing blacklisted_npubs.json"; then
    early="$(grep -E '^compose .* (down|stop)( |$)' "$SB/.rig/calls.log" 2>/dev/null)"
    if [[ -z "$early" ]]; then
      ok "restart after an .env change: the first JSON dialog is up and no down/stop reached the mock"
    else
      bad "restart after an .env change stopped the relay before the dialogs: $(printf '%s' "$early" | sed "s# -f $SB/# -f SB/#" | head -1)"
    fi
    for name in blacklisted_npubs relays_blastr relays_import whitelisted_npubs; do
      wait_for t16 "Missing $name.json" || break
      tmx send-keys -t t16 Enter
    done
    t16_up() { grep -qxF -- "$T16_UP" "$SB/.rig/calls.log" 2>/dev/null; }
    if poll_until "$WAIT_T" t16_up; then
      settle_after t16 "$(sync_n t16)"
    fi
    got="$(unexpected_calls "$SB" "$T16_DRIFT")"
    if [[ "$got" == "$T16_DOWN"$'\n'"$T16_UP" ]]; then
      ok "after the four dialogs the restart runs: down --remove-orphans, then up -d --build"
    else
      bad "restart after the dialogs is not down, then up (got: $(printf '%s' "$got" | sed "s# -f $SB/# -f SB/#" | tr '\n' '|' | head -c 200))"
    fi
  else
    bad "no 'Missing blacklisted_npubs.json' dialog after the .env write ($(capture t16 | tr '\n' '|' | head -c 160))"
  fi
fi
kill_pane t16

# --- 17: TUI stderr stays empty through every view (P5) -------------------------
section "17 TUI stderr"
# The console of a bash TUI is its stderr: a failing command in a render path
# prints there and nothing else notices. A scripted walk through every view and
# dialog (state-changing entries are cancelled at their confirm), then Quit; the
# stderr file must be 0 bytes. Control: a copy with one failing command injected
# into the menu painter makes it non-empty.
tui_walk() { # <session>
  local s="$1" k text
  wait_for "$s" "▸ s Start" || return 1
  for k in s t x r i; do
    case "$k" in
      s) text="Start the relay?" ;;
      t) text="Start the relay with Tor?" ;;
      x) text="Stop the relay (" ;;
      r) text="Restart the relay (" ;;
      i) text="Import notes now?" ;;
    esac
    tmx send-keys -t "$s" "$k"
    wait_for "$s" "$text" || return 1
    tmx send-keys -t "$s" Escape
    wait_absent "$s" "$text" || return 1
  done
  # the data flows, each left before anything runs: Back up at its confirm,
  # the restore list and the switch overview with Esc
  tmx send-keys -t "$s" b
  wait_for "$s" "Back up now? A verified" || return 1
  tmx send-keys -t "$s" Escape
  wait_absent "$s" "Back up now? A verified" || return 1
  for k in e d; do
    case "$k" in
      e) text="backups/, newest first" ;;
      d) text="On disk: " ;;
    esac
    send_settled "$s" "$k"
    wait_for "$s" "$text" || return 1
    send_settled "$s" Tab
    send_settled "$s" Tab
    send_settled "$s" Escape
    wait_for "$s" "▸ s Start" || return 1
  done
  for k in '?' a o u; do
    case "$k" in
      '?') text="Go to nth entry" ;;
      a) text="Relay image digest" ;;
      o) text="No onion address yet" ;;
      u) text="Nothing to add" ;;
    esac
    tmx send-keys -t "$s" "$k"
    wait_for "$s" "$text" || return 1
    tmx send-keys -t "$s" x
    wait_absent "$s" "$text" || return 1
  done
  send_settled "$s" c
  wait_for "$s" "Add setting" || return 1
  goto_item "$s" "relay url" || return 1
  wait_for "$s" "RELAY_URL" || return 1        # the details pane names the key
  send_settled "$s" Enter
  wait_for "$s" "Reveal value" || return 1
  send_settled "$s" Escape
  wait_for "$s" "Add setting" || return 1
  send_settled "$s" Tab
  send_settled "$s" Tab
  tmx send-keys -t "$s" /
  wait_for "$s" "Filter settings:" || return 1
  tmx send-keys -t "$s" -l "limiter"
  poll_until "$WAIT_T" prompt_cell_is "$s" "Filter settings:" "limiter" || return 1
  tmx send-keys -t "$s" Enter
  wait_for "$s" '32 found' || return 1
  send_settled "$s" Escape
  wait_for "$s" "Add setting" || return 1
  send_settled "$s" Escape
  wait_for "$s" "▸ s Start" || return 1
  send_settled "$s" l
  wait_for "$s" "Import relays" || return 1
  send_settled "$s" Enter
  wait_for "$s" "Add item" || return 1
  send_settled "$s" Escape
  send_settled "$s" Escape
  wait_for "$s" "▸ s Start" || return 1
  send_settled "$s" Tab
  wait_for "$s" "│ Status " || return 1
  send_settled "$s" Tab
  tmx send-keys -t "$s" /
  wait_for "$s" "Filter logs:" || return 1
  tmx send-keys -t "$s" -l "=1"
  poll_until "$WAIT_T" prompt_cell_is "$s" "Filter logs:" "=1" || return 1
  tmx send-keys -t "$s" Enter
  wait_for "$s" "matching line" || return 1
  tmx send-keys -t "$s" /
  wait_for "$s" "Filter logs:" || return 1
  tmx send-keys -t "$s" Enter
  wait_absent "$s" "matching line" || return 1
  tmx send-keys -t "$s" q
  poll_until "$WAIT_T" test -s "${SBOF[$s]}/.rig/rc"
}
seed_jsons() { local e; for e in "$1"/*.example.json; do cp "$e" "${e/.example.json/.json}"; done; }
new_sandbox t17
seed_jsons "$SB"
mkdir -m 700 "$SB/backups" && : > "$SB/backups/haven-backup-20260101-000000.zip"
start_pane t17 120 30 "$SB" 'MOCK_LOG_COUNT=20 ./haven tui 2>@RIG@/stderr; echo $? > @RIG@/rc; sleep 30'
if tui_walk t17; then
  if [[ -f "$SB/.rig/stderr" && ! -s "$SB/.rig/stderr" && "$(cat "$SB/.rig/rc")" == 0 ]]; then
    ok "TUI stderr is 0 bytes after a walk through every view (exit 0)"
  else
    bad "TUI stderr after the walk: $(wc -c < "$SB/.rig/stderr" 2>/dev/null) bytes, rc $(cat "$SB/.rig/rc" 2>/dev/null): $(head -c 160 "$SB/.rig/stderr" 2>/dev/null | tr '\n' '|')"
  fi
else
  bad "the scripted walk through the views did not finish ($(capture t17 | tr '\n' '|' | head -c 200))"
fi
kill_pane t17
new_sandbox t17c
seed_jsons "$SB"
# control: one failing command in the menu painter of this copy only
sed -i 's|^tui_render_left_menu() {$|&\n  ls /nonexistent-haven-e2e-probe \|\| true|' "$SB/haven"
start_pane t17c 120 30 "$SB" 'MOCK_LOG_COUNT=20 ./haven tui 2>@RIG@/stderr; echo $? > @RIG@/rc; sleep 30'
if wait_for t17c "▸ s Start"; then
  tmx send-keys -t t17c q
  poll_until "$WAIT_T" test -s "$SB/.rig/rc"
fi
if grep -q 'nonexistent-haven-e2e-probe' "$SB/.rig/stderr" 2>/dev/null; then
  ok "control: an injected failing command shows up in the TUI stderr ($(wc -c < "$SB/.rig/stderr") bytes)"
else
  bad "control: the injected failing command left the stderr file empty — the stderr check has no resolving power"
fi
kill_pane t17c

# --- 18-23: P6 — data flows over the real verbs, settings editor, prompt, leftovers ---
# The flows run the REAL ./haven verbs as children of the TUI, with the scripted
# mock on PATH: backups are real zips (MOCK_RUN_PAYLOAD_FILE), a restore writes
# engine files into the sandbox db/ (MOCK_DB_DIR). Every state-changing docker
# call of a flow sandbox is judged as an exact sequence (paths, the random
# .partial suffix and time stamps normalized) and written to .rig/expected, which
# the isolation proof at the end holds the sandbox to.
FIX_ZIP="$WORK/good.zip"
python3 -I - "$FIX_ZIP" <<'PY2'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for n in ("private", "chat", "outbox", "inbox", "blossom"):
        z.writestr(n + ".jsonl", ("{\"id\":\"%s\"}\n" % n) * 400)
PY2
FLOW_ENV="MOCK_RUN_WRITES=1 MOCK_RUN_PAYLOAD_FILE=$FIX_ZIP MOCK_DB_DIR=@SB@/db"
# state_calls <sandbox> — the state-changing calls of the mock, normalized
state_calls() {
  local sb="$1"
  [[ -f "$sb/.rig/calls.log" ]] || return 0
  grep -E '^(compose .* (stop|start|up|down|run|restart|rm|kill)( |$)|(stop|rm|kill) )' "$sb/.rig/calls.log" \
    | grep -vF -- '--entrypoint cat relay /app/.env.example.upstream' \
    | sed -e "s#$sb/#SB/#g" -e 's/\.partial-[0-9a-f]*/.partial-X/g' -e 's/20[0-9]\{6\}-[0-9]\{6\}/TS/g'
}
# flow_sandbox <name> [engine] — a sandbox with the JSON lists, a badger (or
# lmdb) database of fake files, DOCKER_UID/GID set
flow_sandbox() {
  local n e="${2:-badger}"
  new_sandbox "$1"
  seed_jsons "$SB"
  for n in private chat outbox inbox blossom; do
    mkdir -p "$SB/db/$n"
    if [[ "$e" == badger ]]; then : > "$SB/db/$n/MANIFEST"; else : > "$SB/db/$n/data.mdb"; fi
  done
  printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" >> "$SB/.env"
  sed -i "s/^DB_ENGINE=.*/DB_ENGINE=\"$e\"/" "$SB/.env"
}
flow_pane() { # <session> <cols> <lines> <extra env> — the TUI with the flow mock knobs
  local env="${FLOW_ENV//@SB@/$SB} $4"
  start_pane "$1" "$2" "$3" "$SB" "$env MOCK_LOG_COUNT=10 ./haven tui 2>@RIG@/stderr"
}
T_STOP="compose -f SB/docker-compose.tor.yml stop relay"
T_START="compose -f SB/docker-compose.tor.yml start relay"
T_UPR="compose -f SB/docker-compose.tor.yml up -d relay"
T_RUN="compose -f SB/docker-compose.tor.yml run --rm --no-deps -T --name haven-relay-oneshot -v SB/backups:/app/backups"
# shellcheck disable=SC2016  # the container's sh expands $1
T_BK='--entrypoint sh relay -c umask 077; exec /app/haven backup "$1" sh /app/backups/'
expect_calls() { # <session> <description> <expected lines...>
  local s="$1" what="$2" got want
  shift 2
  want="$(printf '%s\n' "$@")"
  [[ -n "$*" ]] || want=""
  got="$(state_calls "${SBOF[$s]}")"
  printf '%s\n' "$@" > "${SBOF[$s]}/.rig/expected"
  if [[ "$got" == "$want" ]]; then
    ok "$what"
  else
    bad "$what (got: $(tr '\n' '|' <<<"$got" | head -c 400))"
  fi
}

section "18 back up and restore flows"
flow_sandbox t18
flow_pane t18 120 30 ""
if ! wait_for t18 "▸ s Start"; then
  bad "TUI did not start for the backup flow"
else
  send_settled t18 b
  wait_for t18 "Back up now? A verified"
  send_settled t18 Escape
  if wait_absent t18 "Back up now? A verified" && [[ -z "$(state_calls "$SB")" ]]; then
    ok "back up: cancelled at the confirm, no state-changing call"
  else
    bad "back up: cancel at the confirm left calls: $(state_calls "$SB" | tr '\n' '|')"
  fi
  send_settled t18 b
  wait_for t18 "Back up now? A verified"
  tmx send-keys -t t18 Enter
  if wait_for t18 "Backup finished" && wait_for t18 "Written and verified:"; then
    zip="$(find "$SB/backups" -maxdepth 1 -name 'haven-backup-*.zip' -print -quit)"
    if [[ -n "$zip" ]] && unzip -tq "$zip" >/dev/null 2>&1; then
      ok "back up: the box shows the verb's result and a verified zip exists ($(basename "$zip"))"
    else
      bad "back up: no verified zip in backups/"
    fi
  else
    bad "back up: no result box ($(capture t18 | tr '\n' '|' | head -c 200))"
  fi
  expect_calls t18 "back up: exactly the verb's sequence (stop, backup run, start)" \
    "$T_STOP" "$T_RUN ${T_BK}haven-backup-TS.zip.partial-X" "$T_START"
  send_settled t18 x
  wait_for t18 "▸ s Start"
  # restore: two backups, newest first; the older one is chosen
  cp -p "$FIX_ZIP" "$SB/backups/haven-backup-20250101-000000.zip"; touch -d '3 days ago' "$SB/backups/haven-backup-20250101-000000.zip"
  chmod 600 "$SB/backups/"*.zip
  send_settled t18 e
  wait_for t18 "backups/, newest first"
  # a row is the name without "haven-" and ".zip" (the details pane has it whole)
  order="$(left_rows t18 4 28 | grep -oE 'backup-[0-9]{8}-[0-9]{6}' | tr '\n' ' ')"
  zrow="$(basename "$zip" .zip)"
  if [[ "$order" == "${zrow#haven-} backup-20250101-000000 " ]]; then
    ok "restore: the list shows backups/ newest first ($order)"
  else
    bad "restore: list order is '$order'"
  fi
  goto_item t18 "backup-20250101-000000"
  send_settled t18 Enter
  wait_for t18 "Restore haven-backup-20250101"
  send_settled t18 Escape
  if [[ "$(state_calls "$SB" | grep -c ' restore ')" == 0 ]]; then
    ok "restore: cancelled at the TUI's confirm, the verb never ran"
  else
    bad "restore: the verb ran without the TUI's confirm"
  fi
  send_settled t18 Enter
  wait_for t18 "Restore haven-backup-20250101"
  tmx send-keys -t t18 Left Enter
  wait_for t18 "Restore finished" || bad "restore: no result box"
  expect_calls t18 "restore: the chosen file reaches the verb, after the backup's calls" \
    "$T_STOP" "$T_RUN ${T_BK}haven-backup-TS.zip.partial-X" "$T_START" \
    "$T_STOP" "$T_RUN --entrypoint /app/haven relay restore /app/backups/haven-backup-TS.zip" "$T_START"
  if grep -qF -- 'restore /app/backups/haven-backup-20250101-000000.zip' "$SB/.rig/calls.log"; then
    ok "restore: the run names exactly the chosen backup"
  else
    bad "restore: the run does not name the chosen backup"
  fi
fi
kill_pane t18

section "19 engine switch flow"
flow_sandbox t19
flow_pane t19 80 24 "MOCK_RUN_HOLD=1 MOCK_HOLD_AT=1 MOCK_HOLD_MAX=60"
if ! wait_for t19 "▸ s Start"; then
  bad "TUI did not start for the switch flow"
else
  send_settled t19 d
  wait_for t19 "On disk: badger"
  tmx send-keys -t t19 Enter   # opens a prompt: no render passes until it closes
  wait_for t19 "Type lmdb:"
  tmx send-keys -t t19 -l badger
  poll_until "$WAIT_T" prompt_cell_is t19 "Type lmdb:" "badger"
  tmx send-keys -t t19 Enter
  if wait_for t19 "Cancelled: you typed" && [[ -z "$(state_calls "$SB")" ]]; then
    ok "switch: a wrong typed name cancels, no state-changing call"
  else
    bad "switch: wrong typed name did not cancel cleanly"
  fi
  send_settled t19 x
  wait_for t19 "On disk: badger"
  tmx send-keys -t t19 Enter   # opens a prompt: no render passes until it closes
  wait_for t19 "Type lmdb:"
  tmx send-keys -t t19 -l lmdb
  poll_until "$WAIT_T" prompt_cell_is t19 "Type lmdb:" "lmdb"
  tmx send-keys -t t19 Enter
  poll_until "$WAIT_T" test -e "$SB/.rig/started"
  if wait_for t19 "▸ backup"; then
    steps="$(left_rows t19 4 22 | grep -E '^ [✓▸] ' | sed 's/ *$//' | tr '\n' '|')"
    if [[ "$steps" == " ✓ preflight| ✓ stop| ▸ backup|" ]]; then
      ok "switch: held in step 3, the steps from the verb tick in order ($steps)"
    else
      bad "switch: steps on screen are '$steps'"
    fi
  else
    bad "switch: the running step is not shown"
  fi
  if has_text t19 "Relay offline "; then ok "switch: the title row counts the relay's offline time"; else bad "switch: no offline counter in the title row"; fi
  send_settled t19 Escape
  send_settled t19 q
  if has_text t19 "▸ backup" && tui_pid_found t19; then
    ok "switch: Esc and q during the running child do nothing"
  else
    bad "switch: Esc/q changed the running flow"
  fi
  : > "$SB/.rig/release"
  if wait_for t19 "Engine switched"; then
    ok "switch: the success box appears"
  else
    bad "switch: no success box ($(capture t19 | tr '\n' '|' | head -c 200))"
  fi
  if grep -q '^DB_ENGINE="lmdb"' "$SB/.env" && [[ -e "$SB/db/private/data.mdb" ]]; then
    ok "switch: .env and db/ are on lmdb"
  else
    bad "switch: .env/db not on lmdb"
  fi
  expect_calls t19 "switch: exactly the verb's sequence" \
    "$T_STOP" "$T_RUN -e DB_ENGINE=badger ${T_BK}haven-pre-switch-lmdb-TS.zip.partial-X" \
    "$T_RUN -e DB_ENGINE=lmdb --entrypoint /app/haven relay restore /app/backups/haven-pre-switch-lmdb-TS.zip" \
    "$T_RUN -e DB_ENGINE=lmdb ${T_BK}haven-post-switch-lmdb-TS.zip.partial-X" "$T_UPR"
fi
kill_pane t19

# injected restore failure: the 2nd one-shot run (the restore) fails
flow_sandbox t19f
flow_pane t19f 80 24 "MOCK_FAIL_AT=2"
if wait_for t19f "▸ s Start"; then
  send_settled t19f d
  wait_for t19f "On disk: badger"
  tmx send-keys -t t19f Enter
  wait_for t19f "Type lmdb:"
  tmx send-keys -t t19f -l lmdb
  poll_until "$WAIT_T" prompt_cell_is t19f "Type lmdb:" "lmdb"
  tmx send-keys -t t19f Enter
  # the box's title is drawn before its body: poll for the whole sentence
  t19f_box() { [[ "$(left_rows t19f 4 22 | tr -s ' \n' '  ')" == *"Step 'restore' failed; the switch was rolled back: db/ and DB_ENGINE are back on badger."* ]]; }
  if wait_for t19f "Switch rolled back" && poll_until "$WAIT_T" t19f_box; then
    ok "switch: an injected restore failure names the step and the old engine"
  else
    bad "switch: rolled-back box wrong ($(capture t19f | tr '\n' '|' | head -c 240))"
  fi
  if grep -q '^DB_ENGINE="badger"' "$SB/.env" && [[ -e "$SB/db/private/MANIFEST" && ! -e "$SB/db/private/data.mdb" ]] \
    && grep -qx haven-relay "$SB/.rig/running"; then
    ok "switch: after the rollback .env and db/ agree on badger and the relay runs"
  else
    bad "switch: .env/db disagree after the rollback"
  fi
  expect_calls t19f "switch failure: the verb's sequence up to the restore, then the relay back" \
    "$T_STOP" "$T_RUN -e DB_ENGINE=badger ${T_BK}haven-pre-switch-lmdb-TS.zip.partial-X" \
    "$T_RUN -e DB_ENGINE=lmdb --entrypoint /app/haven relay restore /app/backups/haven-pre-switch-lmdb-TS.zip" "$T_UPR"
else
  bad "TUI did not start for the switch failure"
fi
kill_pane t19f

# mixed directories: two --from entries; the chosen side reaches the verb
flow_sandbox t19m lmdb
: > "$SB/db/private/MANIFEST"
flow_pane t19m 80 24 ""
if wait_for t19m "▸ s Start"; then
  send_settled t19m d
  wait_for t19m "On disk: both engines"
  if has_text t19m "From the badger side" && has_text t19m "From the lmdb side"; then
    ok "switch: mixed directories offer the two --from choices"
  else
    bad "switch: the --from choices are missing"
  fi
  goto_item t19m "From the badger side"
  tmx send-keys -t t19m Enter
  wait_for t19m "Type lmdb:"
  tmx send-keys -t t19m -l lmdb
  poll_until "$WAIT_T" prompt_cell_is t19m "Type lmdb:" "lmdb"
  tmx send-keys -t t19m Enter
  wait_for t19m "Engine switched" || wait_for t19m "Switch" || true
  if state_calls "$SB" | grep -qF -- "-e DB_ENGINE=badger ${T_BK}haven-pre-switch-lmdb-TS.zip.partial-X"; then
    ok "switch: the chosen side (--from badger) reaches the verb: its backup reads badger"
  else
    bad "switch: --from badger did not reach the verb ($(state_calls "$SB" | tr '\n' '|' | head -c 200))"
  fi
  state_calls "$SB" > "$SB/.rig/expected"   # judged above by its backup line
else
  bad "TUI did not start for the mixed switch"
fi
kill_pane t19m

# an interrupted switch: the undo entry runs --rollback (the verb refuses the
# planted, unusable marker — its own refusal is what the box shows)
flow_sandbox t19r
printf 'not a marker\n' > "$SB/db/.switch-in-progress"
flow_pane t19r 120 30 ""
if wait_for t19r "▸ s Start" && wait_for t19r "n Undo interrupted switch"; then
  ok "marker: the Data group leads with 'Undo interrupted switch'"
  send_settled t19r n
  wait_for t19r "Undo the interrupted switch?"
  tmx send-keys -t t19r Left Enter
  if wait_for t19r "Undo failed" && wait_for t19r "not a marker this script can use"; then
    ok "marker: the entry ran db-switch --rollback and shows the verb's refusal"
  else
    bad "marker: no rollback result ($(capture t19r | tr '\n' '|' | head -c 200))"
  fi
  expect_calls t19r "marker: the refused rollback changed nothing"
else
  bad "marker: no undo entry in the main menu"
fi
kill_pane t19r

# Ctrl-C while the one-shot is held: the child's guard starts the relay again
flow_sandbox t19c
flow_pane t19c 80 24 "MOCK_RUN_HOLD=1 MOCK_HOLD_MAX=60"
if wait_for t19c "▸ s Start"; then
  send_settled t19c b
  wait_for t19c "Back up now? A verified"
  tmx send-keys -t t19c Enter
  poll_until "$WAIT_T" test -e "$SB/.rig/started"
  wait_for t19c "Backing up"
  tmx send-keys -t t19c C-c
  if wait_for t19c "Backup interrupted" && wait_for t19c "Received SIGINT"; then
    ok "Ctrl-C: the child's guard reported, the TUI shows it"
  else
    bad "Ctrl-C: no interrupted box ($(capture t19c | tr '\n' '|' | head -c 240))"
  fi
  if grep -qx haven-relay "$SB/.rig/running" && grep -qx 'stop -t 10 haven-relay-oneshot' "$SB/.rig/calls.log"; then
    ok "Ctrl-C: the one-shot was stopped and the relay runs again (mock state)"
  else
    bad "Ctrl-C: relay not restarted or one-shot not stopped"
  fi
  send_settled t19c x
  send_settled t19c Down
  if wait_for t19c "▸ t Start with Tor" && tui_pid_found t19c; then
    ok "Ctrl-C: the TUI stays usable afterwards"
  else
    bad "Ctrl-C: the TUI is not usable afterwards"
  fi
  state_calls "$SB" > "$SB/.rig/expected"   # judged above: stop, held run, the guard's restart
else
  bad "TUI did not start for the Ctrl-C check"
fi
kill_pane t19c

section "20 settings editor, prompt, status"
new_sandbox t20
seed_jsons "$SB"
CANARY="CANARY-7f3a9c-SECRET-VALUE-0042"
sed -i "s/^S3_SECRET_KEY=.*/S3_SECRET_KEY=\"$CANARY\"/" "$SB/.env"
printf 'ZZ_ONLY_HERE=1\n' >> "$SB/.env"
env_hash_t20="$(sha256sum "$SB/.env" | cut -d' ' -f1)"
start_pane t20 80 24 "$SB" 'MOCK_LOG_COUNT=10 ./haven tui'
NPUB="npub1utx00neqgqln72j22kej3ux7803c2k986henvvha4thuwfkper4s7r50e8"
if wait_for t20 "▸ s Start"; then
  send_settled t20 c
  wait_for t20 "General"
  if has_text t20 "│ Details" && has_text t20 "Private relay"; then
    ok "settings: section rows and the details pane"
  else
    bad "settings: no sections or no details pane"
  fi
  goto_item t20 "secret key" 80
  if wait_for t20 "S3_SECRET_KEY" && no_text t20 "CANARY"; then
    ok "settings: the canary in S3_SECRET_KEY is shown neither in the list nor in the details pane"
  else
    bad "settings: canary visible or key not shown"
  fi
  send_settled t20 End
  if wait_for t20 "Other" && has_text t20 "zz only here"; then
    ok "settings: a key only in .env is listed under Other"
  else
    bad "settings: no Other section"
  fi
  tmx send-keys -t t20 /
  wait_for t20 "Filter settings:"
  tmx send-keys -t t20 -l zzz
  poll_until "$WAIT_T" prompt_cell_is t20 "Filter settings:" "zzz"
  tmx send-keys -t t20 Enter
  if wait_for t20 'No setting matches "zzz".'; then ok "settings: /zzz shows the empty-state text"; else bad "settings: no empty state"; fi
  send_settled t20 Escape
  if wait_for t20 "Add setting" && has_text t20 "Settings (.env)"; then ok "settings: Esc clears the filter first"; else bad "settings: Esc did not clear the filter"; fi
  if [[ "$(sha256sum "$SB/.env" | cut -d' ' -f1)" == "$env_hash_t20" ]]; then ok "settings: browsing and filtering leave .env byte-identical"; else bad "settings: .env changed"; fi
  send_settled t20 Escape
  wait_for t20 "▸ s Start"
  send_settled t20 Tab
  if wait_for t20 "Last backup  never" && no_text t20 "CANARY"; then
    ok "status: 'never' without a backup, no canary in the status view"
  else
    bad "status: no 'never' line or canary visible"
  fi
  send_settled t20 Tab
  # a 63-character npub typed into a value prompt reaches .env complete
  send_settled t20 c
  wait_for t20 "Add setting"
  goto_item t20 "Add setting"
  prompt_open t20 "New key"
  tmx send-keys -t t20 -l "E2E_TEST_NPUB"
  poll_until "$WAIT_T" prompt_cell_is t20 "New key:" "E2E_TEST_NPUB"
  tmx send-keys -t t20 Enter
  wait_for t20 "New value"
  tmx send-keys -t t20 -l "$NPUB"
  wait_for t20 "…"
  tmx send-keys -t t20 Enter
  if poll_until "$WAIT_T" grep -qx "E2E_TEST_NPUB=$NPUB" "$SB/.env"; then
    ok "prompt: a 63-character npub typed at 80 columns is written to .env complete"
  else
    bad "prompt: the npub did not reach .env ($(grep E2E_TEST_NPUB "$SB/.env"))"
  fi
  # the restart after the write: plain mode (haven-tor is not running)
  t20_up() { grep -qxF -- "compose -f $SB/docker-compose.yml up -d --build" "$SB/.rig/calls.log" 2>/dev/null; }
  poll_until "$WAIT_T" t20_up && settle_after t20 "$(sync_n t20)"
  expect_calls t20 "prompt: the .env write restarts the relay exactly (down, then up)" \
    "compose -f SB/docker-compose.yml down --remove-orphans" "compose -f SB/docker-compose.yml up -d --build"
else
  bad "TUI did not start for the settings check"
fi
kill_pane t20

# --- 22-26: P6 rework — the security audit at terminal level -----------------
# open_setting <session> <KEY> <row label> — the settings list filtered to KEY,
# that row opened (the setting's own menu: Edit value, Reveal value, ...)
open_setting() {
  local s="$1" key="$2" label="$3"
  tmx send-keys -t "$s" /
  wait_for "$s" "Filter settings:" || return 1
  tmx send-keys -t "$s" -l "$key"
  poll_until "$WAIT_T" prompt_cell_is "$s" "Filter settings:" "$key" || return 1
  tmx send-keys -t "$s" Enter
  wait_for "$s" " found" || return 1
  goto_item "$s" "$label" || return 1
  send_settled "$s" Enter
  wait_for "$s" "Reveal value"
}
# left_joined <session> — the left pane's cells of the content rows, joined by
# one blank (a message wrapped over several rows reads as one sentence)
left_joined() {
  local r all=""
  while IFS= read -r r; do all+="$(left_cell "$r") "; done < <(capture "$1" | sed -n '3,$p')
  tr -s ' ' <<<"$all"
}
left_has() { [[ "$(left_joined "$1")" == *"$2"* ]]; }

section "22 pasted .env lines, empty Enter on a masked value (F1, F5)"
new_sandbox t22
seed_jsons "$SB"
printf 'S3_SECRET_KEY=my secret value\n' >> "$SB/.env"   # stored invalid: unquoted spaces
cp "$SB/.env" "$SB/.rig/env-before"
t22_lines="$(grep -c '' "$SB/.env")"
t22_npub="$(grep '^OWNER_NPUB=' "$SB/.env")"
start_pane t22 120 30 "$SB" 'MOCK_LOG_COUNT=10 ./haven tui 2>@RIG@/stderr'
T22_CAPS="$SB/.rig/captures"
: > "$T22_CAPS"
grab22() { capture t22 >> "$T22_CAPS"; }
if ! wait_for t22 "▸ s Start"; then
  bad "TUI did not start for the paste check"
else
  send_settled t22 c
  wait_for t22 "Add setting"
  if open_setting t22 PRIVATE_RELAY_NAME "name" && goto_item t22 "Edit value"; then
    prompt_open t22 "New value"
    # the audit's payload, pasted (bracketed paste: tmux sends ESC[200~ … ESC[201~
    # because the TUI asked for it); the \n are the two printable characters
    tmx set-buffer -b t22 -- '"a"\nOWNER_NPUB=x\nY="b"'
    tmx paste-buffer -p -d -b t22 -t t22
    poll_until "$WAIT_T" prompt_cell_is t22 "New value:" '"a"\nOWNER_NPUB=x\nY="b"'
    tmx send-keys -t t22 Enter
    if poll_until "$WAIT_T" left_has t22 "A value that starts with a quote must end with the same quote"; then
      ok "paste: the pasted \"a\"\\nOWNER_NPUB=x\\nY=\"b\" is refused at the prompt"
    else
      bad "paste: no refusal at the prompt ($(left_joined t22 | head -c 200))"
    fi
    tmx send-keys -t t22 Escape
    wait_absent t22 "New value:"
    if [[ "$(grep -c '' "$SB/.env")" == "$t22_lines" && "$(grep -c '^OWNER_NPUB=' "$SB/.env")" == 1 \
      && "$(grep '^OWNER_NPUB=' "$SB/.env")" == "$t22_npub" ]] && cmp -s "$SB/.env" "$SB/.rig/env-before"; then
      ok "paste: .env byte-identical ($t22_lines lines, one OWNER_NPUB line with its old value)"
    else
      bad "paste: .env changed ($(grep -c '' "$SB/.env") lines, $(grep -c '^OWNER_NPUB=' "$SB/.env") OWNER_NPUB lines)"
    fi
  else
    bad "paste: PRIVATE_RELAY_NAME's Edit value not reachable"
  fi
  # F5: the stored S3_SECRET_KEY is invalid (unquoted spaces); Edit, then Enter on
  # the empty field: no change, no validation, the value never drawn. Esc twice:
  # back to the filtered list, then the filter cleared
  send_settled t22 Escape
  send_settled t22 Escape
  wait_for t22 "Add setting"
  if open_setting t22 S3_SECRET_KEY "secret key" && goto_item t22 "Edit value"; then
    grab22
    prompt_open t22 "New value"
    grab22
    tmx send-keys -t t22 Enter
    grab22
    if wait_absent t22 "New value:"; then
      ok "empty Enter: the prompt closes at once (no change)"
    else
      bad "empty Enter: the prompt stayed open ($(left_joined t22 | head -c 160))"
    fi
    settle_after t22 "$(sync_n t22)"
    grab22
    if ! grep -qF 'my secret value' "$T22_CAPS" && ! grep -qF 'must be quoted' "$T22_CAPS"; then
      ok "empty Enter: the clear value and a validation error appear in none of $(grep -c '' "$T22_CAPS") captured rows"
    else
      bad "empty Enter: the clear value or a validation error was drawn ($(grep -m1 -E 'my secret value|must be quoted' "$T22_CAPS" | head -c 120))"
    fi
    if cmp -s "$SB/.env" "$SB/.rig/env-before"; then ok "empty Enter: .env byte-identical"; else bad "empty Enter: .env changed"; fi
  else
    bad "empty Enter: S3_SECRET_KEY's Edit value not reachable"
  fi
  expect_calls t22 "F1/F5: nothing written, nothing restarted (no state-changing docker call)"
fi
kill_pane t22

section "23 crafted output of a flow's child (F2)"
flow_sandbox t23
printf 'osc52 \033]52;c;SGVsbG8gd29ybGQ=\007 end\ncsi \2332J 8-bit and \302\2332J c1\nfake Backup written: backups/forged.zip (9 KiB, x)   ::result ok\n\033]2;PWNED-TITLE\007title\n' > "$SB/.rig/crafted"
flow_pane t23 120 30 "MOCK_RUN_OUTPUT_FILE=$SB/.rig/crafted"
tmx set -s set-clipboard on   # an OSC 52 that reaches tmux would create a buffer
if ! wait_for t23 "▸ s Start"; then
  bad "TUI did not start for the crafted-output check"
else
  t23_title="$(tmx display -p -t t23 '#{pane_title}')"
  send_settled t23 b
  wait_for t23 "Back up now? A verified"
  tmx send-keys -t t23 Enter
  if wait_for t23 "Backup finished" && wait_for t23 "Written and verified:"; then
    raw="$(tmx capture-pane -p -e -t t23)"
    if [[ "$raw" != *$'\e]'* && "$raw" != *$'\x9b'* && "$raw" != *$'\xc2\x9b'* && "$raw" != *"PWNED"* ]] \
      && has_text t23 "osc52 end" && has_text t23 "csi 2J 8-bit and 2J c1"; then
      ok "crafted output: shown as text, no OSC, 8-bit CSI or C1 CSI in capture-pane -e"
    else
      bad "crafted output: an escape reached the screen ($(printf '%s' "$raw" | LC_ALL=C grep -aoE $'\e\\][^\a]{0,20}|\x9b.{0,4}' | head -2 | od -c | head -2 | tr '\n' ' '))"
    fi
    if [[ -z "$(tmx list-buffers 2>/dev/null)" && "$(tmx display -p -t t23 '#{pane_title}')" == "$t23_title" ]]; then
      ok "crafted output: no tmux buffer set (OSC 52), the pane title is unchanged (OSC 2)"
    else
      bad "crafted output: buffers [$(tmx list-buffers 2>/dev/null | head -1)], title [$(tmx display -p -t t23 '#{pane_title}')]"
    fi
    # the forged line stays text in the output pane; the box (left pane) must
    # be built from the verb's own line
    t23_box="$(left_joined t23)"
    if [[ "$t23_box" == *"Written and verified: backups/haven-backup-"* && "$t23_box" != *forged* ]]; then
      ok "crafted output: the box names the real backup, not the forged line"
    else
      bad "crafted output: the box took the forged line ($(head -c 160 <<<"$t23_box"))"
    fi
  else
    bad "crafted output: no result box ($(capture t23 | tr '\n' '|' | head -c 200))"
  fi
  expect_calls t23 "crafted output: the verb's sequence is unchanged (stop, backup run, start)" \
    "$T_STOP" "$T_RUN ${T_BK}haven-backup-TS.zip.partial-X" "$T_START"
fi
kill_pane t23

section "24 Ctrl-C at the result box, cleanup with a piped stdin (F4)"
# The window "child reaped, box not yet dismissed" made deterministic: the box
# waits for a key, so once its title is on screen the child has been reaped
# (tui_flow_run waited for it) and the box is still up — Ctrl-C lands inside it.
flow_sandbox t24
flow_pane t24 120 30 ""
if ! wait_for t24 "▸ s Start"; then
  bad "TUI did not start for the Ctrl-C check"
else
  send_settled t24 b
  wait_for t24 "Back up now? A verified"
  tmx send-keys -t t24 Enter
  if wait_for t24 "Backup finished"; then
    send_settled t24 C-c
    send_settled t24 C-c
    if tui_pid_found t24 && has_text t24 "Backup finished" && [[ "$(tmx display -p -t t24 '#{alternate_on}')" == 1 ]]; then
      ok "Ctrl-C at the result box: the TUI keeps running and the box stays"
    else
      bad "Ctrl-C at the result box: TUI pid $(tui_pid t24 || echo gone), alternate_on $(tmx display -p -t t24 '#{alternate_on}' 2>/dev/null)"
    fi
    send_settled t24 x
    if wait_for t24 "▸ s Start"; then
      t24_pid="$(tui_pid t24)"
      tmx send-keys -t t24 C-c
      t24_gone() { ! kill -0 "$t24_pid" 2>/dev/null; }
      if [[ -n "$t24_pid" ]] && poll_until "$WAIT_T" t24_gone; then
        ok "after the box is dismissed Ctrl-C quits the TUI again"
      else
        bad "after the box Ctrl-C did not quit the TUI"
      fi
    else
      bad "the box did not close with a key"
    fi
  else
    bad "Ctrl-C check: no result box"
  fi
  if [[ -f "$SB/.rig/stderr" && ! -s "$SB/.rig/stderr" ]]; then
    ok "Ctrl-C check: TUI stderr is 0 bytes"
  else
    bad "Ctrl-C check: TUI stderr $(wc -c < "$SB/.rig/stderr" 2>/dev/null) bytes: $(head -c 120 "$SB/.rig/stderr" 2>/dev/null | tr '\n' '|')"
  fi
  expect_calls t24 "Ctrl-C check: the backup's sequence only (stop, backup run, start)" \
    "$T_STOP" "$T_RUN ${T_BK}haven-backup-TS.zip.partial-X" "$T_START"
fi
kill_pane t24
new_sandbox t24c
# tui_init in a subshell, then tui_cleanup with stdin from a pipe and no EXIT
# trap to mend it: the terminal modes and the alternate screen must be back
SYNC=0 start_pane t24c 80 24 "$SB" 'b0="$(stty -g)"; ( source ./haven; tui_init; trap - EXIT INT TERM; echo x | tui_cleanup ); echo "rc=$?" > @RIG@/rc.tmp; b1="$(stty -g)"; [ "$b0" = "$b1" ] && echo same > @RIG@/stty || echo differ > @RIG@/stty; mv @RIG@/rc.tmp @RIG@/rc; sleep 30'
if poll_until "$WAIT_T" test -s "$SB/.rig/rc"; then
  alt="$(tmx display -p -t t24c '#{alternate_on}')"
  if [[ "$(cat "$SB/.rig/rc")" == rc=0 && "$alt" == 0 && "$(cat "$SB/.rig/stty")" == same ]]; then
    ok "tui_cleanup with a piped stdin: rc 0, alternate screen off, terminal modes restored"
  else
    bad "tui_cleanup with a piped stdin: $(cat "$SB/.rig/rc"), alternate_on=$alt, stty $(cat "$SB/.rig/stty")"
  fi
else
  bad "tui_cleanup check did not finish"
fi
kill_pane t24c

section "25 restart after a saved setting keeps the frame"
new_sandbox t25
seed_jsons "$SB"
T25_DOWN="compose -f SB/docker-compose.yml down --remove-orphans"
T25_UP="compose -f SB/docker-compose.yml up -d --build"
start_pane t25 120 30 "$SB" 'MOCK_LOG_COUNT=10 ./haven tui 2>@RIG@/stderr'
if ! wait_for t25 "▸ s Start"; then
  bad "TUI did not start for the restart-frame check"
else
  send_settled t25 c
  wait_for t25 "Add setting"
  if open_setting t25 PRIVATE_RELAY_NAME "name" && goto_item t25 "Edit value"; then
    prompt_open t25 "New value"
    tmx send-keys -t t25 -l '"Renamed relay"'
    poll_until "$WAIT_T" prompt_cell_is t25 "New value:" '"Renamed relay"'
    tmx send-keys -t t25 Enter
    if poll_until "$WAIT_T" left_has t25 ".env was saved and the relay restarted"; then
      settle_after t25 "$(sync_n t25)"
      geometry_case t25 120 30 "after the restart of a saved setting"
      if no_text t25 "STATUS" && no_text t25 "Up 2 hours" && no_text t25 "Starting services"; then
        ok "restart: none of compose's output (ps lines with a tab) is on the screen"
      else
        bad "restart: compose output on the screen ($(capture t25 | grep -m1 -E 'STATUS|Up 2|Starting' | head -c 100))"
      fi
    else
      bad "restart: no result box after the save ($(capture t25 | tr '\n' '|' | head -c 200))"
    fi
  else
    bad "restart: PRIVATE_RELAY_NAME's Edit value not reachable"
  fi
  grep -qx 'PRIVATE_RELAY_NAME="Renamed relay"' "$SB/.env" || bad "restart: the value did not reach .env"
  expect_calls t25 "restart: down, then up (as before)" "$T25_DOWN" "$T25_UP"
fi
kill_pane t25

section "21 leftovers"
new_sandbox t21
start_pane t21 80 24 "$SB" 'MOCK_LOG_COUNT=10 ./haven tui'
if wait_for t21 "▸ s Start"; then
  send_settled t21 Escape
  send_settled t21 Left
  if tui_pid_found t21 && has_text t21 "▸ s Start"; then ok "Esc and ← in the main view leave the TUI running"; else bad "Esc/← quit the TUI"; fi
  t21_pid="$(tui_pid t21)"
  tmx send-keys -t t21 q
  t21_gone() { ! kill -0 "$t21_pid" 2>/dev/null; }
  if poll_until "$WAIT_T" t21_gone; then ok "q quits from the main view"; else bad "q did not quit"; fi
fi
kill_pane t21
new_sandbox t21d
SYNC=0 start_pane t21d 80 24 "$SB" 'TERM=dumb ./haven tui > @RIG@/out 2>&1; echo $? > @RIG@/rc; sleep 30'
poll_until "$WAIT_T" test -s "$SB/.rig/rc"
if [[ "$(cat "$SB/.rig/rc")" != 0 ]] && grep -q 'the TUI needs a terminal that can position the cursor' "$SB/.rig/out" \
  && [[ "$(wc -l < "$SB/.rig/out")" -eq 1 ]]; then
  ok "TERM=dumb: exit $(cat "$SB/.rig/rc") with one sentence naming the commands"
else
  bad "TERM=dumb: rc $(cat "$SB/.rig/rc"), output $(head -c 160 "$SB/.rig/out")"
fi
kill_pane t21d

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
section "isolation proofs"
# 1) every call that reached the mock of any sandbox is read-only or expected — the
#    one provoked on purpose is the env write of check 13, which makes the TUI restart
#    a running relay (down, then up) and probe the upstream .env.example (read-only).
#    Allowlist: anything else fails the run and is printed, whatever its verb.
unexpected=0
seen=0
for sb in "${SANDBOXES[@]}"; do
  [[ -f "$sb/.rig/calls.log" ]] || continue
  seen=$((seen + $(wc -l < "$sb/.rig/calls.log")))
  if [[ "$sb" == */sb-t13 ]]; then
    # the restart of check 13 is judged THERE (exact sequence); here it is only the
    # allowance: its own down, its own up, and the read-only drift probe — exact lines
    out="$(unexpected_calls "$sb" "$T13_DOWN" "$T13_UP" "$T13_DRIFT")"
  elif [[ -f "$sb/.rig/expected" ]]; then
    # a flow sandbox: its state-changing calls were judged in its check as an
    # exact sequence; here they must be exactly those, nothing else
    out="$(diff <(state_calls "$sb") <(grep -v '^$' "$sb/.rig/expected") | grep '^[<>]' || true)"
    [[ -z "$out" ]] || out="$(printf '%s\n' "$out"; unexpected_calls "$sb" | grep -vE '^(compose .* (stop|start|up|down|run|restart|rm|kill)( |$)|(stop|rm|kill) )' || true)"
    [[ -n "$out" ]] || out="$(unexpected_calls "$sb" | grep -vE '^(compose .* (stop|start|up|down|run|restart|rm|kill)( |$)|(stop|rm|kill) )' || true)"
  elif [[ "$sb" == */sb-t16 ]]; then
    # the same allowance for the restart of check 16 (judged there, in order)
    out="$(unexpected_calls "$sb" "$T16_DOWN" "$T16_UP" "$T16_DRIFT")"
  else
    out="$(unexpected_calls "$sb")"
  fi
  if [[ -n "$out" ]]; then
    say "  unexpected docker call(s) in $(basename "$sb"):"
    while IFS= read -r line; do say "    ${line//"$sb/"/SB/}"; done <<< "$out"
    unexpected=$((unexpected + $(printf '%s\n' "$out" | wc -l)))
  fi
done
if [[ "$unexpected" -eq 0 && "$seen" -gt 0 ]]; then
  ok "no unexpected state-changing docker call reached the mock (${#SANDBOXES[@]} sandboxes, $seen calls all read-only or expected)"
else
  bad "no unexpected state-changing docker call reached the mock ($unexpected unexpected of $seen calls)"
fi
# 2) the real tree is exactly as it was
FP_AFTER="$(fingerprint)"
if [[ "$FP_BEFORE" == "$FP_AFTER" ]]; then
  ok "real repo untouched (.env, db/ + blossom/, git status fingerprints identical)"
else
  bad "real repo changed during the run"
fi

section_end
say "TIME: whole run $(( ($(now_ms) - RUN_T0) / 1000 )) s"
say ""
say "e2e-tui: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
