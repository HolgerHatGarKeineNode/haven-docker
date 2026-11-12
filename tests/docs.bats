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
  grep -qF '| `q` / `Q` | Back one view; from the main view, quit |' "$README"
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
