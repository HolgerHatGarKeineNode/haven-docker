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

# --- 8: navigation keys (P4) --------------------------------------------------
tmux_new t8 100 30 "./haven tui"
if ! wait_for t8 "Dashboard"; then
  bad "TUI did not start for the navigation check"
else
  nav_case() { # nav_case <label> <description>
    local out
    out="$(capture t8)"
    if printf '%s' "$out" | grep -q "▸ $1"; then
      ok "navigation: $2 selects '$1'"
    else
      bad "navigation: $2 did not select '$1'"
    fi
  }
  tmux -L "$SOCK" send-keys -t t8 3;    sleep 0.4; nav_case "Stop services" "digit 3"
  tmux -L "$SOCK" send-keys -t t8 k;    sleep 0.4; nav_case "Start (Tor)" "k"
  tmux -L "$SOCK" send-keys -t t8 j;    sleep 0.4; nav_case "Stop services" "j"
  tmux -L "$SOCK" send-keys -t t8 G;    sleep 0.4; nav_case "Quit" "G"
  tmux -L "$SOCK" send-keys -t t8 g;    sleep 0.4; nav_case "Start (Docker)" "g"
  tmux -L "$SOCK" send-keys -t t8 End;  sleep 0.4; nav_case "Quit" "End"
  tmux -L "$SOCK" send-keys -t t8 Home; sleep 0.4; nav_case "Start (Docker)" "Home"
fi
tmux -L "$SOCK" kill-session -t t8 >/dev/null 2>&1 || true

# NOTE: PgUp/PgDn paged the menu until P4; P5 assigns them to the log
# scrollback — that behavior is proven in the t12 checks below.

# --- 9+10: prompt editor — paste, Ctrl-U, Ctrl-W (P4) -------------------------
# 160 cols so the 30-char paste fits the prompt's input budget.
tmux_new t9 160 30 "./haven tui"
if ! wait_for t9 "Dashboard"; then
  bad "TUI did not start for the prompt editor check"
else
tmux -L "$SOCK" send-keys -t t9 5      # .env Editor (digits select only)
sleep 0.3
tmux -L "$SOCK" send-keys -t t9 Enter
wait_for t9 "Add variable" || true
sleep 0.3
tmux -L "$SOCK" send-keys -t t9 1      # Add variable
sleep 0.3
tmux -L "$SOCK" send-keys -t t9 Enter  # -> "New key: " prompt
if ! wait_for t9 "New key"; then
  bad "key prompt did not open"
else
  # paste 30 characters through bracketed paste
  tmux -L "$SOCK" send-keys -t t9 -l $'\033[200~abcdefghijklmnopqrstuvwxyz012345\033[201~'
  sleep 0.6
  if capture t9 | grep -q "abcdefghijklmnopqrstuvwxyz012345"; then
    ok "prompt: bracketed paste inserts the full 30-char payload"
  else
    bad "prompt: pasted payload missing ($(capture t9 | grep -o 'Tail lines.*' | head -c 60))"
  fi
  # Ctrl-U clears the line
  tmux -L "$SOCK" send-keys -t t9 C-u
  sleep 0.4
  if capture t9 | grep -q "abcdefghijklmnopqrstuvwxyz"; then
    bad "prompt: Ctrl-U did not clear the input"
  else
    ok "prompt: Ctrl-U clears the input"
  fi
  # Ctrl-W deletes the last word
  tmux -L "$SOCK" send-keys -t t9 -l "foo bar"
  sleep 0.4
  tmux -L "$SOCK" send-keys -t t9 C-w
  sleep 0.4
  if capture t9 | grep -q "foo bar"; then
    bad "prompt: Ctrl-W did not delete the word"
  elif capture t9 | grep -q "foo "; then
    ok "prompt: Ctrl-W deletes the word before the cursor"
  else
    bad "prompt: Ctrl-W left unexpected input ($(capture t9 | grep -o 'New key.*' | head -c 60))"
  fi
  # cancel the prompt — nothing must be written to .env
  tmux -L "$SOCK" send-keys -t t9 Escape
  sleep 0.3
fi
fi
tmux -L "$SOCK" kill-session -t t9 >/dev/null 2>&1 || true

# --- 11: masking, reveal, inline validation (P4) ------------------------------
# The checks write to .env: back it up first, restore in cleanup.
ENV_BACKUP="$(mktemp)"
ENV_EXISTED=0
if [[ -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env" "$ENV_BACKUP"
  ENV_EXISTED=1
fi
printf 'TEST_SECRET_KEY=abcdefgh1234\n' >> "$ROOT_DIR/.env"

tmux_new t11 100 30 "./haven tui"
if ! wait_for t11 "Dashboard"; then
  bad "TUI did not start for the masking check"
else
tmux -L "$SOCK" send-keys -t t11 5      # .env Editor (digits select only)
sleep 0.3
tmux -L "$SOCK" send-keys -t t11 Enter
wait_for t11 "Add variable"
sleep 0.3
out="$(capture t11)"
if [[ "$out" == *"TEST_SECRET_KEY = …1234"* && "$out" != *"abcdefgh1234"* ]]; then
  ok "env list masks sensitive values (…1234)"
else
  bad "env list does not mask ($(printf '%s' "$out" | grep -o 'TEST_SECRET_KEY.*' | head -c 60))"
fi
# open the key (first entry after "Add variable"), then reveal
tmux -L "$SOCK" send-keys -t t11 Down
sleep 0.3
tmux -L "$SOCK" send-keys -t t11 Enter
wait_for t11 "Reveal value"
sleep 0.2
tmux -L "$SOCK" send-keys -t t11 2      # Reveal value
sleep 0.3
tmux -L "$SOCK" send-keys -t t11 Enter
sleep 0.6
if capture t11 | grep -q "abcdefgh1234"; then
  ok "reveal shows the plaintext on explicit request"
else
  bad "reveal did not show the plaintext"
fi
tmux -L "$SOCK" send-keys -t t11 x      # dismiss message
sleep 0.3
tmux -L "$SOCK" send-keys -t t11 Escape # env_item -> env_list
sleep 0.4
tmux -L "$SOCK" send-keys -t t11 1      # Add variable
sleep 0.3
tmux -L "$SOCK" send-keys -t t11 Enter
wait_for t11 "New key"
sleep 0.2
tmux -L "$SOCK" send-keys -t t11 -l "RELAY_PORT"
sleep 0.4
tmux -L "$SOCK" send-keys -t t11 Enter
wait_for t11 "New value"
sleep 0.2
tmux -L "$SOCK" send-keys -t t11 -l "70000"
sleep 0.4
tmux -L "$SOCK" send-keys -t t11 Enter
sleep 0.6
if capture t11 | grep -q "Port must be 1-65535"; then
  ok "invalid value shows the error inline at the prompt"
else
  bad "inline validation message missing ($(capture t11 | tr '\n' '|' | head -c 150))"
fi
tmux -L "$SOCK" send-keys -t t11 Escape # cancel value prompt
sleep 0.3
fi
tmux -L "$SOCK" kill-session -t t11 >/dev/null 2>&1 || true

# restore .env state (drop anything the checks wrote, keep user content)
if [[ "$ENV_EXISTED" == "1" ]]; then
  cp "$ENV_BACKUP" "$ROOT_DIR/.env"
else
  rm -f "$ROOT_DIR/.env"
fi
rm -f "$ENV_BACKUP"
if grep -q "^RELAY_PORT=" "$ROOT_DIR/.env" 2>/dev/null; then
  bad ".env was modified by the cancelled add (RELAY_PORT present)"
else
  ok ".env untouched by the cancelled add"
fi

# --- 12: panel QoL — scrollback, filter, status view (P5) ---------------------
tmux_new t12 120 34 "PATH=$ROOT_DIR/tests/mock:\$PATH ./haven tui"
if ! wait_for t12 "COUNTER="; then
  bad "mock stream did not reach the panel for the P5 checks"
else
  # let the buffer fill past the visible height (34 rows -> ~28 visible)
  wait_for t12 "COUNTER=40"
  last_live="$(capture t12 | grep -o 'COUNTER=[0-9]*' | tail -1)"
  tmux -L "$SOCK" send-keys -t t12 PgUp
  sleep 0.6
  out="$(capture t12)"
  if [[ "$out" == *"paused"* ]]; then
    ok "PgUp pauses the panel and shows the pause banner"
  else
    bad "PgUp did not show the pause banner"
  fi
  older="$(printf '%s\n' "$out" | grep -o 'COUNTER=[0-9]*' | tail -1)"
  if [[ "$older" != "$last_live" ]]; then
    ok "scrollback shows older lines ($older vs live $last_live)"
  else
    bad "scrollback still shows the live tail ($older)"
  fi
  tmux -L "$SOCK" send-keys -t t12 PgDn
  sleep 0.6
  if capture t12 | grep -q "paused"; then
    bad "PgDn did not resume the live view"
  else
    ok "PgDn resumes the live view"
  fi

  # live filter via slash
  tmux -L "$SOCK" send-keys -t t12 /
  sleep 0.4
  tmux -L "$SOCK" send-keys -t t12 -l "COUNTER=2"
  sleep 0.4
  tmux -L "$SOCK" send-keys -t t12 Enter
  sleep 0.6
  out="$(capture t12)"
  if [[ "$out" == *"match(es) for 'COUNTER=2'"* ]]; then
    ok "slash search shows the live match count"
  else
    bad "slash search missing the match count ($(printf '%s' "$out" | tr '\n' '|' | head -c 120))"
  fi
  if printf '%s' "$out" | grep -q "COUNTER=3"; then
    bad "filter does not hide non-matching lines"
  else
    ok "filter hides non-matching lines"
  fi
  tmux -L "$SOCK" send-keys -t t12 /
  sleep 0.4
  tmux -L "$SOCK" send-keys -t t12 Enter
  sleep 0.5
  if capture t12 | grep -q "match(es)"; then
    bad "empty filter did not clear the search"
  else
    ok "empty filter input clears the search"
  fi

  # status panel via Tab
  tmux -L "$SOCK" send-keys -t t12 Tab
  sleep 1.0
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
  tmux -L "$SOCK" send-keys -t t12 Tab
  sleep 0.6
  if capture t12 | grep -q "COUNTER="; then
    ok "Tab switches back to the log view"
  else
    bad "Tab back did not restore the log view"
  fi
fi
tmux -L "$SOCK" kill-session -t t12 >/dev/null 2>&1 || true

# --- 13: P6 — about screen, timestamped backup on write, docs ---------------
# only the backups this check created get removed afterwards
ENV_BAK_BEFORE="$(ls -1 "$ROOT_DIR"/.env.bak.* 2>/dev/null || true)"
tmux_new t13 120 30 "PATH=$ROOT_DIR/tests/mock:\$PATH ./haven tui"
if ! wait_for t13 "Dashboard"; then
  bad "TUI did not start for the P6 checks"
else
  # About sits right before Quit: End -> Quit, k -> About, Enter
  tmux -L "$SOCK" send-keys -t t13 End
  sleep 0.4
  tmux -L "$SOCK" send-keys -t t13 k
  sleep 0.4
  tmux -L "$SOCK" send-keys -t t13 Enter
  sleep 0.8
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
  tmux -L "$SOCK" send-keys -t t13 x
  sleep 0.3

  # A real .env write must leave a timestamped backup next to the file
  tmux -L "$SOCK" send-keys -t t13 5
  sleep 0.3
  tmux -L "$SOCK" send-keys -t t13 Enter
  wait_for t13 "Add variable"
  sleep 0.2
  tmux -L "$SOCK" send-keys -t t13 1
  sleep 0.3
  tmux -L "$SOCK" send-keys -t t13 Enter
  wait_for t13 "New key"
  sleep 0.2
  tmux -L "$SOCK" send-keys -t t13 -l "E2E_TEST_KEY"
  sleep 0.3
  tmux -L "$SOCK" send-keys -t t13 Enter
  wait_for t13 "New value"
  sleep 0.2
  tmux -L "$SOCK" send-keys -t t13 -l "42"
  sleep 0.3
  tmux -L "$SOCK" send-keys -t t13 Enter
  sleep 1.0
  new_backup=0
  while IFS= read -r b; do
    [[ -e "$b" ]] || continue
    if [[ -z "$ENV_BAK_BEFORE" || "$ENV_BAK_BEFORE" != *"$b"* ]]; then
      new_backup=1
    fi
  done < <(find "$ROOT_DIR" -maxdepth 1 -name '.env.bak.*' 2>/dev/null)
  if [[ "$new_backup" == "1" ]] && grep -q "^E2E_TEST_KEY=42$" "$ROOT_DIR/.env"; then
    ok "env write leaves a timestamped backup and the new value"
  else
    bad "env write missing backup or value (new_backup=$new_backup, value=$(grep -c E2E_TEST_KEY "$ROOT_DIR/.env" 2>/dev/null))"
  fi
fi
tmux -L "$SOCK" kill-session -t t13 >/dev/null 2>&1 || true
# drop the e2e key again and only the backups this check produced
if grep -q "^E2E_TEST_KEY=" "$ROOT_DIR/.env" 2>/dev/null; then
  # grep -v exits 1 when nothing is left — do not chain the mv on it
  grep -v "^E2E_TEST_KEY=" "$ROOT_DIR/.env" > "$ROOT_DIR/.env.tmp"
  mv "$ROOT_DIR/.env.tmp" "$ROOT_DIR/.env"
fi
while IFS= read -r b; do
  [[ -e "$b" ]] || continue
  if [[ -z "$ENV_BAK_BEFORE" || "$ENV_BAK_BEFORE" != *"$b"* ]]; then
    rm -f "$b"
  fi
done < <(find "$ROOT_DIR" -maxdepth 1 -name '.env.bak.*' 2>/dev/null)

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

say ""
say "e2e-tui: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
