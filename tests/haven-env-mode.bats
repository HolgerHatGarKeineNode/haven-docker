#!/usr/bin/env bats
# Every writer of .env keeps the file's mode and owner, and the temporary file
# it writes first is never more permissive than .env (R1 of the P3 extension:
# `awk > .env.tmp; mv` turned a 0600 .env into 0644 under umask 022).
#
# How "never more permissive" is observed: stand-ins for awk and mv come first
# on PATH and log the mode of the temporary file at the two moments it can be
# looked at with content in it — while awk writes into it (awk's stdout is the
# temporary file) and right before mv renames it over .env. Before the first
# moment the file is either absent or empty (mktemp creates it 0600, empty);
# after the second it IS .env. With the stand-ins delegating to the real tools,
# the logged modes are the modes the real run had.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sandbox"
  mkdir -p "$SB" "$TEST_DIR/bin"
  cp "$REPO_ROOT/haven" "$SB/"
  export MODE_LOG="$TEST_DIR/modes.log"
  : > "$MODE_LOG"
  local real_awk real_mv
  real_awk="$(command -v awk)"
  real_mv="$(command -v mv)"
  # awk: when its stdout is a temporary .env file, log that file's mode
  cat > "$TEST_DIR/bin/awk" <<SH
#!/usr/bin/env bash
t="\$(readlink /proc/\$\$/fd/1 2>/dev/null)"
case "\${t##*/}" in
  .env.tmp|.env.tmp.*) printf 'awk %s\n' "\$(stat -c %a "\$t")" >> "\$MODE_LOG" ;;
esac
exec "$real_awk" "\$@"
SH
  # mv: log the mode of a temporary .env file it is about to rename
  cat > "$TEST_DIR/bin/mv" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\${a##*/}" in
    .env.tmp|.env.tmp.*) [ -f "\$a" ] && printf 'mv %s\n' "\$(stat -c %a "\$a")" >> "\$MODE_LOG" ;;
  esac
done
exec "$real_mv" "\$@"
SH
  chmod +x "$TEST_DIR/bin/awk" "$TEST_DIR/bin/mv"
  printf 'RELAY_PORT=3355\nSECRET_KEY=abc\n' > "$SB/.env"
  printf 'RELAY_PORT=3355\nSECRET_KEY=\nNEW_KEY=1\n' > "$SB/.env.example"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# in_sandbox <mode of .env> <shell code> — runs with umask 022 and the stand-ins
in_sandbox() {
  chmod "$1" "$SB/.env"
  OWNER_BEFORE="$(stat -c %u:%g "$SB/.env")"
  run env PATH="$TEST_DIR/bin:$PATH" bash -c 'umask 022; cd "$1"; source ./haven; set +e; '"$2" _ "$SB"
  echo "$output"
  echo "--- modes"; cat "$MODE_LOG"
}

# the logged modes: at least one awk and one mv entry, none looser than $1
# (no bit outside $1), and the file renamed at exactly $1
assert_modes() { # <mode of .env>
  local want="$1" kind m
  grep -q '^awk ' "$MODE_LOG"
  grep -q '^mv ' "$MODE_LOG"
  while read -r kind m; do
    (( (8#$m & ~8#$want) == 0 )) || { echo "$kind saw $m, looser than $want"; return 1; }
    if [ "$kind" = mv ]; then [ "$m" = "$want" ] || { echo "renamed at $m, not $want"; return 1; }; fi
  done < "$MODE_LOG"
  [ "$(stat -c %a "$SB/.env")" = "$want" ]
  [ "$(stat -c %u:%g "$SB/.env")" = "$OWNER_BEFORE" ]
  [ -z "$(find "$SB" -maxdepth 1 -name '.env.tmp*' -print -quit)" ]
}

@test "set_env_var keeps a 0600 .env at 0600 under umask 022; the temporary file is never looser" {
  in_sandbox 600 'set_env_var RELAY_PORT 4444; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  grep -qx 'RELAY_PORT=4444' "$SB/.env"
  assert_modes 600
}

@test "remove_env_var keeps a 0600 .env at 0600 under umask 022; the temporary file is never looser" {
  in_sandbox 600 'remove_env_var SECRET_KEY; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  ! grep -q '^SECRET_KEY=' "$SB/.env"
  assert_modes 600
}

@test "env-upgrade (upgrade_env_file) keeps a 0600 .env at 0600 under umask 022; the temporary file is never looser" {
  in_sandbox 600 'upgrade_env_file; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  grep -qx 'NEW_KEY=1' "$SB/.env"
  assert_modes 600
}

@test "the CLI verb env-upgrade keeps a 0600 .env at 0600 under umask 022" {
  chmod 600 "$SB/.env"
  # the verb runs main(), and main() asks docker for compose first: the mock
  # answers, not the host's docker (the suite tripwire fails the run otherwise)
  run env PATH="$TEST_DIR/bin:$REPO_ROOT/tests/mock:$PATH" MOCK_DOCKER_STATE_DIR="$TEST_DIR/state" \
    bash -c 'umask 022; cd "$1" && ./haven env-upgrade' _ "$SB"
  echo "$output"; cat "$MODE_LOG"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/state/calls.log")" = "compose version" ]
  grep -qx 'NEW_KEY=1' "$SB/.env"
  OWNER_BEFORE="$(stat -c %u:%g "$SB/.env")"
  assert_modes 600
}

@test "the db-switch rollback writer (dbs_env_put) keeps a 0600 .env at 0600 under umask 022" {
  printf 'DB_ENGINE=badger\n' >> "$SB/.env"
  in_sandbox 600 'DBS_ENV_SET=1 DBS_ENV_LINE="DB_ENGINE=lmdb"; dbs_env_put; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  grep -qx 'DB_ENGINE=lmdb' "$SB/.env"
  assert_modes 600
}

@test "a 0640 .env stays 0640, and the temporary file has no group bit while it is written" {
  in_sandbox 640 'set_env_var RELAY_PORT 4444; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  grep -qx 'awk 600' "$MODE_LOG"
  assert_modes 640
}

@test "a 0400 .env stays 0400; the temporary file is written at 0400 through the already open descriptor" {
  in_sandbox 400 'set_env_var RELAY_PORT 4444; echo "rc=$?"'
  [[ "$output" == *"rc=0"* ]]
  grep -qx 'awk 400' "$MODE_LOG"
  grep -qx 'RELAY_PORT=4444' "$SB/.env"
  assert_modes 400
}

@test "a failing writer leaves .env byte-identical and no temporary file behind" {
  chmod 600 "$SB/.env"
  cp -p "$SB/.env" "$TEST_DIR/env.before"
  run bash -c 'umask 022; cd "$1"; source ./haven; set +e; replace_file_from "$1/.env" false; echo "rc=$? err=$REPLACE_ERR"' _ "$SB"
  echo "$output"
  [[ "$output" == *"rc=1 err=cannot write the new content of .env; it was not changed"* ]]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  [ "$(stat -c %a "$SB/.env")" = 600 ]
  [ -z "$(find "$SB" -maxdepth 1 -name '.env.tmp*' -print -quit)" ]
}
