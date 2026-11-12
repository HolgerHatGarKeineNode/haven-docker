#!/usr/bin/env bats
# The README and the CHANGELOG keep up with the CLI: every verb `./haven help`
# lists is shown in the README as `./haven <verb>`, the backup, restore and
# engine-switch words are there, the plain-compose recipes the real-Docker
# script runs verbatim exist, and the top CHANGELOG entry references issue #15.
# `./haven help` runs from a sandbox copy with the docker mock first on PATH.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
README="$REPO_ROOT/README.md"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

setup() {
  TEST_DIR="$(mktemp -d)"
  cp "$REPO_ROOT/haven" "$TEST_DIR/"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

help_verbs() {
  PATH="$REPO_ROOT/tests/mock:$PATH" "$TEST_DIR/haven" help </dev/null \
    | awk '/^Commands:/ {on = 1; next} /^Options:/ {on = 0} on && /^  [a-z]/ {print $1}' | sort -u
}
# readme_shows <verb> — `./haven <verb>` followed by a space, a backtick or the line end
readme_shows() { grep -qE "\./haven $1( |\`|\$)" "$README"; }

@test "docs: every verb ./haven help lists appears in the README as ./haven <verb>" {
  local verbs v missing=""
  verbs="$(help_verbs)"
  echo "help verbs: $verbs"
  [ "$(printf '%s\n' "$verbs" | grep -c .)" -ge 10 ]
  for v in backup restore db-switch; do printf '%s\n' "$verbs" | grep -qx "$v"; done
  while IFS= read -r v; do
    readme_shows "$v" || missing+="$v "
  done <<< "$verbs"
  echo "missing: $missing"
  [ -z "$missing" ]
  # positive control: the check does see a verb the README does not show
  ! readme_shows frobnicate-not-a-verb
}

@test "docs: the README names backup, restore, db-switch, --from and --rollback" {
  grep -qF './haven backup' "$README"
  grep -qF './haven restore <file>' "$README"
  grep -qF './haven db-switch lmdb' "$README"
  grep -qF -- '--from badger' "$README"
  grep -qF './haven db-switch --rollback' "$README"
  grep -q '^### Switching the database engine$' "$README"
  grep -q '^#### If you already changed DB_ENGINE by hand$' "$README"
}

@test "docs: the plain-compose recipes the real-Docker script runs are in the README" {
  local r
  for r in backup restore switch; do
    grep -q "^<!-- recipe:$r " "$README"
  done
  grep -qxF 'docker compose run --rm --no-deps -v ./backups:/app/backups --entrypoint /app/haven relay backup /app/backups/haven-backup.zip' "$README"
}

@test "docs: the top CHANGELOG entry references issue #15" {
  awk '/^## / {n++} n == 1' "$CHANGELOG" > "$TEST_DIR/top"
  head -n1 "$TEST_DIR/top"
  [ -s "$TEST_DIR/top" ]
  grep -qF '[#15](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/15)' "$TEST_DIR/top"
}

@test "docs: the README describes the TUI's settings editor, flows, status view and keys" {
  grep -q '^## The TUI$' "$README"
  grep -qF '`/` finds settings by name, short name' "$README"
  grep -qF 'Undo interrupted switch' "$README"
  grep -qF 'group and section rows do not count' "$README"
  grep -qF '| `q` / `Q` | Back one view (in the settings list a search is cleared first); from the main view, quit |' "$README"
  grep -qF '| `Ctrl-C` | Quit the TUI' "$README"
  grep -qF 'nothing in the main view' "$README"
  grep -qF 'cursor (`TERM=dumb`) the TUI does not' "$README"
  # the old claims are gone
  ! grep -qF 'from the main view, quit |'$'\n''| `q` |' "$README"
  ! grep -qF 'or `TERM=dumb`, it draws without colours' "$README"
}

@test "docs: the help screen names q, Q and Ctrl-C like the README" {
  PATH="$REPO_ROOT/tests/mock:$PATH" run bash -c 'source '"$TEST_DIR"'/haven; set +e; TUI_ACTIVE=0; clear() { :; }; pause() { :; }; show_help_screen'
  [[ "$output" == *"q Q       Back; quit in"* ]]
  [[ "$output" == *"Ctrl-C    Quit"* ]]
  [[ "$output" == *"Esc ←     Back"* ]]
  [[ "$output" != *"Back, or quit"* ]]
}

# The real-Docker TUI script waits for screen text; a reworded dialog left it
# waiting into its timeout (exit 1) with every bats case green. Every literal it
# waits for must occur in ./haven verbatim, or — for a text the TUI composes at
# run time — each of its listed source pieces must.
@test "docs: every text tests/real-docker/*.sh waits for occurs in ./haven" {
  declare -A pieces=(
    ["Backup finished"]='tui_flow_outcome "Backup"|_TITLE="$1 finished"'
    ["On disk: badger"]='"On disk: $FLOW_FOUND"|FLOW_FOUND="badger"'
    ["Restore haven-backup-"]='tui_confirm "Restore $name?|name="haven-backup-'
    ["▸ s Start"]='ICO_SELECTED="▸ "|MENU_IDS=(group:relay start_plain|MENU_LABELS=("Relay" "Start"|MENU_KEYS=("" s t x r'
    ["Type lmdb:"]='tui_prompt "Type $FLOW_TARGET:"|FLOW_TARGET="lmdb"'
  )
  local lits lit missing="" p n=0
  lits="$(grep -ohE '(wait_text|has) "[^"$]+"' "$REPO_ROOT"/tests/real-docker/*.sh | sed -E 's/^(wait_text|has) "//; s/"$//' | sort -u)"
  while IFS= read -r lit; do
    [[ -n "$lit" ]] || continue
    n=$((n + 1))
    if [[ -n "${pieces[$lit]+x}" ]]; then
      while IFS= read -r p; do
        grep -qF -- "$p" "$REPO_ROOT/haven" || missing+="[$lit: piece $p] "
      done < <(tr '|' '\n' <<<"${pieces[$lit]}")
    else
      grep -qF -- "$lit" "$REPO_ROOT/haven" || missing+="[$lit] "
    fi
  done <<<"$lits"
  echo "literals: $n; missing: $missing"
  [ "$n" -ge 10 ]
  [ -z "$missing" ]
}

# B3 (P6 final rework): two sentences that said more than the code does
@test "docs: the CHANGELOG's control-character sentence says the prompt drops them from a paste" {
  local flat
  flat="$(tr '\n' ' ' < "$CHANGELOG" | tr -s ' ')"
  [[ "$flat" == *"the prompt drops line breaks, tabs and other control characters from a paste, and a value that still holds one (line break, tab, escape) when it is checked or written is refused for every setting"* ]]
  [[ "$flat" != *"(line break, tab, escape) is refused for every setting"* ]]
}

@test "docs: the README's masking sentence matches mask_env_value (… plus the last four above eight characters, … alone otherwise)" {
  local flat
  flat="$(tr '\n' ' ' < "$README" | tr -s ' ')"
  [[ "$flat" == *'Credentials are masked: a value longer than eight characters shows `…` and its last four characters, a value of eight characters or fewer only `…`.'* ]]
  [[ "$flat" != *"show only their last four characters"* ]]
  run bash -c 'source "$1"; set +e; for v in 12345678 123456789; do mask_env_value "$v"; echo "$v=$_MASKED"; done' _ "$TEST_DIR/haven"
  [ "${lines[0]}" = "12345678=…" ]
  [ "${lines[1]}" = "123456789=…6789" ]
}

# C2: the masking sentence names the boundary exactly — derived from
# mask_env_value, not written into the test: the longest value that shows `…`
# alone (L) must be "of L characters or fewer", and "longer than L" shows the
# last four
@test "docs: the README's masking sentence states the boundary mask_env_value implements (C2)" {
  local flat words=(zero one two three four five six seven eight nine ten eleven twelve) L
  run bash -c 'source "$1"; set +e; v=""; for n in $(seq 1 20); do v+=x; mask_env_value "$v"; echo "$n $_MASKED"; done' _ "$TEST_DIR/haven"
  L="$(printf '%s\n' "$output" | awk '$2 == "…" {l = $1} END {print l}')"
  echo "longest value masked as … alone: $L"
  [[ "$L" =~ ^[0-9]+$ ]] && (( L >= 1 && L < ${#words[@]} ))
  printf '%s\n' "$output" | awk -v l="$L" '$1 > l && $2 != "…xxxx" {bad = 1} END {exit bad}'
  flat="$(tr '\n' ' ' < "$README" | tr -s ' ')"
  [[ "$flat" == *"a value longer than ${words[L]} characters shows \`…\` and its last four characters, a value of ${words[L]} characters or fewer only \`…\`."* ]]
  # the old wording left the boundary itself undefined
  [[ "$flat" != *"a shorter one only"* ]]
}

# C1: the top CHANGELOG entry carries the behaviour the P6 final rework added
@test "docs: the top CHANGELOG entry names the duplicated-key, restart-box, \$-note, quoting, writer, log-pane and terminal changes (C1)" {
  local top missing="" l
  top="$(awk '/^## / {n++} n == 1' "$CHANGELOG" | tr '\n' ' ' | tr -s ' ')"
  while IFS= read -r l; do
    [[ -z "$l" || "$top" == *"$l"* ]] || missing+="[$l] "
  done <<'LINES'
the start checks and every other place that reads a setting use its last assignment, the one Docker Compose uses
the box reports the relay's real state as Docker shows it after the restart; a write that is refused or fails is shown in the box and restarts nothing
a value that contains `$` outside single quotes gets a note in the details pane and in the box after saving it: Docker Compose expands `$NAME` and `${NAME}` there
Single-quoted values follow the same backslash rule as double-quoted ones
checked against what Docker Compose parses
A write to `.env` that is interrupted (Ctrl-C, `kill`, a closed terminal) finishes first or cleans up after itself; its temporary files (`.env.tmp.*`, `.env.pre.*`) are git-ignored
The TUI log pane removes terminal control sequences from log lines
The TUI restores the terminal after Ctrl-C and after `kill`
An error inside a TUI menu action is shown in its box and no longer resets the terminal under the running TUI
LINES
  echo "missing: $missing"
  [ -z "$missing" ]
  # no internal names in the entry's new lines
  ! grep -nE 'writer_guard|run_capture|read_env_var|env_dollar_note|tui_|TUI_ACTIVE|log_sanitize' <<<"$top"
}
