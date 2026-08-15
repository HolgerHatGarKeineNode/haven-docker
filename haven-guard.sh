#!/bin/sh
# Installed as /app/haven inside the image; the relay binary itself is
# /app/haven-bin.
#
# Two different programs are called "haven": this repo's CLI on the host, and
# upstream's binary in the container. `docker exec haven-relay ./haven import`
# picks the second one, opens db/ a second time while the running relay still
# holds the lock, and dies in badger with a bare "Cannot acquire directory lock"
# panic that names neither program (issue #12). The panic is correct and
# useless — this guard turns it into the instruction the user was looking for.
#
# The test is not "am I a docker exec" but "is another haven-bin already
# running", which is what actually decides whether db/ is taken: scan /proc for
# a second process whose executable is haven-bin. That leaves every legitimate
# path alone — the relay started by entrypoint.sh and the one-shot import
# container that `./haven import` spawns via `docker compose run` are each the
# only haven-bin in their own container.

set -e

case "${1:-}" in
  help|-h|--help) exec /app/haven-bin "$@" ;;
esac

# Check both /proc/<pid>/exe and the cmdline: exe is the authoritative answer
# for the real, statically linked binary but needs the same uid, while cmdline
# is world-readable and is what identifies a wrapped or scripted haven-bin. A
# pid that exits mid-scan just drops out.
other_haven_pid=""
for proc_dir in /proc/[0-9]*; do
  pid="${proc_dir#/proc/}"
  [ "$pid" = "$$" ] && continue

  exe="$(readlink "$proc_dir/exe" 2>/dev/null || true)"
  cmdline="$(tr -d '\000' < "$proc_dir/cmdline" 2>/dev/null || true)"

  case "$exe$cmdline" in
    *haven-bin*) other_haven_pid="$pid"; break ;;
  esac
done

if [ -n "$other_haven_pid" ]; then
  cmd="${1:-<no argument — starts the relay>}"

  echo "🚫 haven is already running in this container (pid $other_haven_pid) and holds the exclusive lock on db/." >&2
  echo "   '$cmd' opens the same database and would panic in badger." >&2
  echo >&2
  echo "   You are inside the container. Run this on the host, in your haven-docker checkout:" >&2
  if [ "${1:-}" = "import" ]; then
    echo >&2
    echo "       ./haven import" >&2
    echo >&2
    echo "   It stops the relay, imports once in the foreground, and starts the relay again." >&2
  else
    echo >&2
    echo "       ./haven stop" >&2
    echo >&2
    echo "   ...and run your command against the stopped relay. See ./haven help." >&2
  fi
  exit 1
fi

exec /app/haven-bin "$@"
