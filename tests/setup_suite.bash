#!/usr/bin/env bash
# Suite-level guard: no test in tests/*.bats executes the host's docker or
# docker-compose. bats loads this file by itself for every run that starts in
# tests/ (`bats tests/`, `bats tests/*.bats`, a single file); it needs bats 1.7.
#
# setup_suite puts a tripwire (tests/docker-tripwire.sh, installed under both
# names) first on PATH. Every test file inherits that PATH, a new one included,
# so the host's binaries are shadowed without any line in the test file. A test
# that needs docker puts the mock in front: PATH="$REPO_ROOT/tests/mock:$PATH".
#
# teardown_suite fails the run ("not ok … teardown_suite", exit 1) when the
# tripwire recorded a call, and names file, test and argv of each. It is a
# failure and never a skip: before this guard `./haven env-upgrade` in
# tests/haven-env-mode.bats ran the host's `docker compose version`, and the
# suite stayed green.
#
# What this does not see: a test that replaces PATH instead of extending it
# (tests/suite-guard.bats scans the test files for that), and a docker binary
# named by an absolute path.

setup_suite() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HAVEN_TRIPWIRE_DIR="$BATS_SUITE_TMPDIR/docker-tripwire"
  HAVEN_TRIPWIRE_LOG="$BATS_SUITE_TMPDIR/docker-tripwire.log"
  mkdir -p "$HAVEN_TRIPWIRE_DIR"
  cp "$here/docker-tripwire.sh" "$HAVEN_TRIPWIRE_DIR/docker"
  cp "$here/docker-tripwire.sh" "$HAVEN_TRIPWIRE_DIR/docker-compose"
  chmod +x "$HAVEN_TRIPWIRE_DIR/docker" "$HAVEN_TRIPWIRE_DIR/docker-compose"
  : > "$HAVEN_TRIPWIRE_LOG"
  PATH="$HAVEN_TRIPWIRE_DIR:$PATH"
  export PATH HAVEN_TRIPWIRE_DIR HAVEN_TRIPWIRE_LOG
}

teardown_suite() {
  [[ -s "$HAVEN_TRIPWIRE_LOG" ]] || return 0
  {
    echo "docker was called without the mock. On this host that call would have reached the real"
    echo "docker daemon. Put tests/mock first on PATH in the test (or stub docker in it):"
    sed 's/^/  /' "$HAVEN_TRIPWIRE_LOG"
  } >&2
  return 1
}
