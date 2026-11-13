#!/usr/bin/env bash
# Tripwire for the bats suite. tests/setup_suite.bash installs this file as
# `docker` and as `docker-compose` in a directory of its own and puts that
# directory first on PATH for the whole run, so it stands where the host's
# binaries would be found. A test that wants docker puts tests/mock in front of
# it; a call that arrives here came from a test without the mock.
#
# The call is recorded (file, test, argv) and refused with exit 97. The real
# binary is never executed. The record matters more than the exit status: the
# caller may swallow a failing docker (./haven reports "Docker is offline" and
# goes on), so teardown_suite reads the record and fails the run.

name="${0##*/}"
args="$*"
args="${args//$'\n'/\\n}"
record="${BATS_TEST_FILENAME##*/}: \"${BATS_TEST_DESCRIPTION:-outside a test}\": $name $args"

if [[ -n "${HAVEN_TRIPWIRE_LOG:-}" ]]; then
  printf '%s\n' "$record" >> "$HAVEN_TRIPWIRE_LOG"
fi
printf 'haven tests: %s was called without tests/mock first on PATH (%s)\n' "$name" "$record" >&2
exit 97
