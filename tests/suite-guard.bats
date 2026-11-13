#!/usr/bin/env bats
# The suite-level guard of tests/setup_suite.bash: no test executes the host's
# docker or docker-compose. Here: the guard is armed in this very run, what a
# call into the tripwire leaves behind, and — with a nested bats run on a
# throwaway test file — that such a call turns the run red even when the test
# itself swallows the failure, while a test with the mock in front stays green.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
bats_require_minimum_version 1.7.0

setup() {
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# inner <name> <test body> — a one-test file in the test dir, run by a nested
# bats with the real setup_suite.bash. The nested run installs its own tripwire
# and its own log in front of this run's; nothing reaches the log of this run.
# (`bats` inside a test is bats' own libexec entry; it needs the environment of
# the outer run, so the environment is passed on as it is.)
inner() {
  printf '@test "inner: %s" {\n%s\n}\n' "$1" "$2" > "$TEST_DIR/$1.bats"
  REPO_ROOT="$REPO_ROOT" run bats --setup-suite-file "$REPO_ROOT/tests/setup_suite.bash" "$TEST_DIR/$1.bats"
  echo "$output"
}

@test "suite guard: docker and docker-compose resolve to the tripwire in the PATH every test file inherits" {
  # red when setup_suite.bash did not run (file gone or renamed, bats older than 1.7)
  [ -n "${HAVEN_TRIPWIRE_DIR:-}" ]
  [ "$(type -P docker)" = "$HAVEN_TRIPWIRE_DIR/docker" ]
  [ "$(type -P docker-compose)" = "$HAVEN_TRIPWIRE_DIR/docker-compose" ]
  [ -f "$HAVEN_TRIPWIRE_LOG" ]
}

@test "suite guard: a call into the tripwire is refused with exit 97 and recorded with file, test and argv" {
  # a private log, so this deliberate call does not fail the run
  HAVEN_TRIPWIRE_LOG="$TEST_DIR/log" run docker compose -f "a b.yml" version
  [ "$status" -eq 97 ]
  [[ "$output" == *"docker was called without tests/mock first on PATH"* ]]
  HAVEN_TRIPWIRE_LOG="$TEST_DIR/log" run docker-compose ps
  [ "$status" -eq 97 ]
  cat "$TEST_DIR/log"
  local me='suite-guard.bats: "suite guard: a call into the tripwire is refused with exit 97 and recorded with file, test and argv": '
  [ "$(cat "$TEST_DIR/log")" = "${me}docker compose -f a b.yml version
${me}docker-compose ps" ]
}

@test "suite guard: a test that reaches docker without the mock fails the run, even when it swallows the failure" {
  inner unguarded '  docker compose version || true'
  [ "$status" -eq 1 ]
  [[ "$output" == *"ok 1 inner: unguarded"* ]]
  [[ "$output" == *"not ok 2 teardown_suite"* ]]
  [[ "$output" == *'unguarded.bats: "inner: unguarded": docker compose version'* ]]
}

@test "suite guard: docker-compose is covered as well; the mock in front of docker does not hide it" {
  inner legacy '  export PATH="$REPO_ROOT/tests/mock:$PATH"
  docker-compose version || true'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 2 teardown_suite"* ]]
  [[ "$output" == *'legacy.bats: "inner: legacy": docker-compose version'* ]]
}

@test "suite guard: a test with the mock first on PATH passes and leaves the run green" {
  inner mocked '  export PATH="$REPO_ROOT/tests/mock:$PATH"
  docker compose version'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 inner: mocked"* ]]
  [[ "$output" != *"teardown_suite"* ]]
}

# Structural, the one case the tripwire cannot see: it is found through PATH,
# so a test that sets PATH to a fresh value (no inherited tail) walks past it.
# Checked per line: every PATH assignment in tests/*.bats ends in the inherited
# $PATH. Not covered: an assignment split over lines, a PATH built in a helper
# script, a docker binary named by an absolute path.
@test "suite guard: every PATH assignment in tests/*.bats keeps the inherited PATH, which carries the tripwire" {
  local hits bad n
  hits="$(grep -nE '(^|[^[:alnum:]_])PATH[=]' "$REPO_ROOT"/tests/*.bats | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  n="$(grep -c . <<<"$hits")"
  bad="$(grep -vE 'PATH[=]"?[^[:space:]"]*:\$\{?PATH\}?"?([[:space:]]|$)' <<<"$hits" || true)"
  echo "PATH assignments: $n"; echo "replacing PATH: $bad"
  [ "$n" -ge 17 ]   # the scan finds the assignments at all (17 when this was written)
  [ -z "$bad" ]
}
