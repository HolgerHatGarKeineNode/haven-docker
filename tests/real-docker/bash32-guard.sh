#!/usr/bin/env bash
# Real measurement of the bash version guard: ./haven run by bash 3.2 (what
# macOS ships), from the official Docker image bash:3.2. `help`, the call
# without an argument and one verb must each end with exit 1 and the line
# "haven: bash 4.2 or newer is required, found 3.2.x", and bash must not get as
# far as its own complaint ("declare: -A: invalid option", exit 2 — what help
# and the bare call did until image v1.2.2-7).
#
# This is the part tests/haven-bash-guard.bats cannot do: that file runs the
# guard on the host's bash with a stand-in version. Whether bash 3.2 can parse
# and run the lines up to and including the guard is only seen here.
#
# OPT-IN. Not a bats test; needs a running Docker daemon and the image already
# present locally (it never pulls: `docker pull bash:3.2` is yours to run).
#
#   HAVEN_REAL_DOCKER=1 [BASH32_IMAGE=bash:3.2] tests/real-docker/bash32-guard.sh
#
# ISOLATION
#   - ./haven is mounted alone and read-only; nothing else of the repo is
#     visible in the container, and the container has no network
#   - every container runs with --rm under an own name `havenit-bash32-<random>-<n>`
#     and is removed by that name in a trap as well (a `timeout` ends only the
#     docker client, never the container)
#   - own work dir from mktemp, removed in the trap
#
# STEPS
#   image     the image's bash reports 3.2.x
#   help, no-argument, status
#             exit 1, first line is the guard's, no "declare:" in the output
#   control   the same script with the guard block cut out (a copy in the work
#             dir): bash 3.2 does not end it cleanly — the measurement can fail
#   closing   ./haven unchanged, no container of this run left

set -u
set -o pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SELF=$(basename "$0")

die() { echo "$SELF: $*" >&2; exit 1; }

if [ "${HAVEN_REAL_DOCKER:-}" != "1" ]; then
  echo "$SELF: opt-in measurement against a real Docker daemon. Set HAVEN_REAL_DOCKER=1 to run it." >&2
  exit 2
fi

for t in docker timeout awk mktemp od cksum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

IMAGE=${BASH32_IMAGE:-bash:3.2}
docker image inspect -f '{{.Id}}' "$IMAGE" >/dev/null 2>&1 \
  || die "image $IMAGE is not present locally (this script never pulls). Fetch it once yourself: docker pull $IMAGE"

PROJ="havenit-bash32-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$PROJ.XXXXXX") || die "mktemp failed"
N=0
FAIL=0
OUT=""
RC=0

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
  local rc=$? i
  trap - EXIT INT TERM
  for ((i = 1; i <= N; i++)); do
    docker rm -f "$PROJ-$i" >/dev/null 2>&1
  done
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check() { # name yes/no detail
  echo "  [$1] $2 — $3"
  [ "$2" = yes ] || FAIL=1
}

# in32 <file on the host> <command...> — the file mounted read-only as
# /w/haven, the command run in the image; sets OUT (stdout and stderr) and RC
in32() {
  local file="$1"
  shift
  N=$((N + 1))
  OUT=$(timeout 120 docker run --rm --pull never --network none --name "$PROJ-$N" \
    -e TERM=xterm -v "$file:/w/haven:ro" -w /w "$IMAGE" "$@" 2>&1 </dev/null)
  RC=$?
}

has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
lacks() { ! has "$1"; }
first_line() { printf '%s\n' "$OUT" | head -n 1; }
show() { echo "--- $1: exit $RC"; printf '%s\n' "$OUT" | sed 's/^/    /'; }

sum_before=$(cksum <"$REPO/haven")

# ---------------------------------------------------------------------- image
# shellcheck disable=SC2016  # expanded by the bash in the container, not here
in32 "$REPO/haven" bash -c 'printf %s "$BASH_VERSION"'
VER=$OUT
case "$VER" in
  3.2.*) check image yes "$IMAGE runs bash $VER" ;;
  *) check image no "$IMAGE runs bash '$VER' (exit $RC), not 3.2.x"; exit 1 ;;
esac

# --------------------------------------------------------------- the three calls
measure() { # label [args of ./haven]
  local label="$1" ok=yes why=""
  shift
  in32 "$REPO/haven" bash /w/haven "$@"
  show "$label"
  [ "$RC" = 1 ] || { ok=no; why+=" exit $RC, not 1;"; }
  has "haven: bash 4.2 or newer is required, found" || { ok=no; why+=" the guard's line is missing;"; }
  [ "$(first_line)" = "haven: bash 4.2 or newer is required, found $VER." ] || { ok=no; why+=" first line is not the guard's;"; }
  lacks "declare:" || { ok=no; why+=" bash reached a declare it cannot run;"; }
  check "$label" "$ok" "exit $RC; first line: $(first_line)${why:+ —$why}"
}

measure help help
measure no-argument
measure status status

# -------------------------------------------------------------------- control
# the guard block cut out of a copy: bash 3.2 must not end that script cleanly
awk '/^if \(\( BASH_VERSINFO\[0\] < 4/ { cut = 1 } !cut { print } cut && /^fi$/ { cut = 0 }' \
  "$REPO/haven" >"$WORK/haven-unguarded"
if cmp -s "$REPO/haven" "$WORK/haven-unguarded"; then
  check control no "cannot cut the guard block out of ./haven (its first line changed); adjust the pattern here"
else
  in32 "$WORK/haven-unguarded" bash /w/haven help
  show "control (guard cut out), help"
  if [ "$RC" != 0 ] && lacks "bash 4.2 or newer is required"; then
    check control yes "without the guard bash $VER ends help with exit $RC: $(first_line)"
  else
    check control no "without the guard help ended with exit $RC: $(first_line)"
  fi
fi

# -------------------------------------------------------------------- closing
check haven-unchanged "$([ "$(cksum <"$REPO/haven")" = "$sum_before" ] && echo yes || echo no)" "./haven has the checksum it had before"
left=$(docker ps -a --filter "name=$PROJ" -q | wc -l)
check no-leftovers "$([ "$left" -eq 0 ] && echo yes || echo no)" "containers named $PROJ-* after the run: $left"

echo "elapsed: ${SECONDS}s"
exit "$FAIL"
