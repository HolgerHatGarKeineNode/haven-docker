#!/usr/bin/env bats
# The bash version guard at the top of ./haven: on a bash older than 4.2 every
# call — help in each spelling, no argument, any verb — ends with exit 1 and
# the "bash 4.2 or newer is required" line, and nothing else of the script runs
# first. Until image v1.2.2-7 a `case` exempted help and the bare call; on bash
# 3.2 those died at the first top-level `declare -A` ("declare: -A: invalid
# option", rc 2).
#
# How an old bash is produced here without one: BASH_VERSINFO and BASH_VERSION
# are readonly, so the test runs a copy of ./haven in which exactly these two
# names are replaced by stand-ins (HAVEN_T_VERSINFO, HAVEN_T_VERSION), and a
# BASH_ENV file gives the stand-ins the values bash 3.2.57 reports. The guard
# that runs is the script's own line; only where it reads the version from is
# changed.
#
# "Nothing else runs first" is observed, not read: the BASH_ENV file also sets
# a DEBUG trap that records the line of every top-level command and ends the
# script with exit 99 after 20 of them (so a script that is not stopped by the
# guard fails at once instead of opening the TUI). Every command recorded
# before the guard's version test must be one of BEFORE_GUARD below.
#
# What this does NOT cover — it runs on the host's bash, not on 3.2:
#   - whether bash 3.2 can parse and run the BEFORE_GUARD lines and the guard
#     itself (its own syntax, the printf lines);
#   - any failure bash 3.2 would have that the host's bash does not.
# Both are measured for real by tests/real-docker/bash32-guard.sh (opt-in).
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
bats_require_minimum_version 1.5.0

# The commands that may run before the guard decides, as written in ./haven.
# Add a line here only after tests/real-docker/bash32-guard.sh passed with it:
# this list is the one part of the test that is taken on trust.
BEFORE_GUARD="$(cat <<'EOF'
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
EOF
)"

setup() {
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sb"
  TRACE="$TEST_DIR/trace"
  mkdir -p "$SB"
  sed 's/BASH_VERSINFO/HAVEN_T_VERSINFO/g; s/BASH_VERSION/HAVEN_T_VERSION/g' "$REPO_ROOT/haven" > "$SB/haven"
  # a script the guard lets through reaches main(), which asks docker first
  export MOCK_DOCKER_STATE_DIR="$TEST_DIR/state"
  PATH="$REPO_ROOT/tests/mock:$PATH"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# as_bash <major> <minor> <patch> [traced] — the BASH_ENV file for one version
as_bash() {
  VERSION="$1.$2.$3(1)-release"
  {
    printf 'HAVEN_T_VERSINFO=(%s %s %s 1 release x86_64-pc-linux-gnu)\n' "$1" "$2" "$3"
    printf "HAVEN_T_VERSION='%s'\n" "$VERSION"
    if [[ "${4:-}" == traced ]]; then
      cat <<EOF
__haven_t_seen=0
__haven_t_trace() {
  printf '%s\n' "\$1" >> "$TRACE"
  (( ++__haven_t_seen <= 20 )) || { echo "NOT-STOPPED: 20 commands ran and the guard did not end the script" >&2; exit 99; }
}
trap '__haven_t_trace "\$LINENO"' DEBUG
EOF
    fi
  } > "$TEST_DIR/bash.env"
}

# haven_run [args] — the copy, run as a script by a bash that reads BASH_ENV
haven_run() {
  : > "$TRACE"
  rm -rf "$MOCK_DOCKER_STATE_DIR"
  run --separate-stderr env BASH_ENV="$TEST_DIR/bash.env" bash "$SB/haven" "$@" </dev/null
  echo "--- haven $* -> status=$status"
  echo "stdout=[$output]"
  echo "stderr=[$stderr]"
  echo "trace=[$(tr '\n' ' ' < "$TRACE")]"
}

# every command recorded before the guard's version test is one of BEFORE_GUARD
guard_ran_first() {
  local n text
  while read -r n; do
    text="$(sed -n "${n}p" "$SB/haven")"
    [[ "$text" == *HAVEN_T_VERSINFO* ]] && return 0
    grep -qxF -- "$text" <<<"$BEFORE_GUARD" || { echo "ran before the guard, line $n: $text"; return 1; }
  done < "$TRACE"
  echo "the guard's version test never ran"
  return 1
}

assert_refused() {
  [ "$status" -eq 1 ]
  [ "${stderr_lines[0]}" = "haven: bash 4.2 or newer is required, found $VERSION." ]
  [ -z "$output" ]                               # no usage, no screen
  [ ! -e "$MOCK_DOCKER_STATE_DIR/calls.log" ]    # no docker call
  guard_ran_first
}

@test "bash guard: on bash 3.2 help is refused in every spelling, before anything else runs" {
  as_bash 3 2 57 traced
  local arg
  for arg in help -h --help; do
    haven_run "$arg"
    assert_refused
  done
}

@test "bash guard: on bash 3.2 the call without an argument is refused, before anything else runs" {
  as_bash 3 2 57 traced
  haven_run
  assert_refused
}

@test "bash guard: on bash 3.2 a verb, the TUI and an unknown word are refused, before anything else runs" {
  as_bash 3 2 57 traced
  local arg
  for arg in status tui no-such-verb; do
    haven_run "$arg"
    assert_refused
  done
}

@test "bash guard: 4.1 and everything older is refused" {
  local v
  for v in "4 1 17" "4 0 44" "3 1 23" "3 0 16" "2 5 0"; do
    IFS=' ' read -r major minor patch <<<"$v"
    as_bash "$major" "$minor" "$patch" traced
    haven_run help
    assert_refused
  done
}

@test "bash guard: 4.2 and everything newer passes, help prints the usage" {
  local v
  for v in "4 2 0" "4 4 23" "5 0 0" "5 3 9" "10 0 0"; do
    IFS=' ' read -r major minor patch <<<"$v"
    as_bash "$major" "$minor" "$patch"
    haven_run help
    [ "$status" -eq 0 ]
    [[ "$output" == "Haven CLI & TUI"* ]]
    [[ "$output" == *"Usage:"* ]]
    [[ "$stderr" != *"is required"* ]]
  done
}
