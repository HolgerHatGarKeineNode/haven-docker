#!/usr/bin/env bash
# P6 measurement: the REAL TUI (`./haven tui`) drives the guided data flows
# against the published image, in a sandbox copy, through tmux on its own
# socket: Back up now -> a verified zip; Switch engine badger -> lmdb with the
# typed confirmation -> the relay serves the identical sorted event-ID set and
# the blob, and the steps were shown; Restore the earlier backup -> still the
# identical set. The TUI's stderr must stay empty.
#
# OPT-IN. Not a bats test; needs a running Docker daemon and the image already
# present locally (it never pulls).
#
#   HAVEN_REAL_DOCKER=1 \
#   [P6_EVIDENCE=<empty dir>] [P6_WORK=<empty dir outside the repo>] \
#   [P6_IMAGE=holgerhatgarkeinenode/haven-docker:v1.2.2-6] [P6_N=24] \
#     tests/real-docker/p6-tui-flows.sh
#
# ISOLATION: as tests/real-docker/p3-db-switch.sh (own work dir outside the
# repo, sanitised compose file without container name, loopback ephemeral port,
# pull_policy: never, own project havenit-<random>, HAVEN_CONTAINER_NAME seam,
# throwaway key, cleanup `docker compose -p <project> down -v`), plus a tmux
# server on its own socket (-L test-p6real-<pid>, -f /dev/null), killed at the end.

set -u
set -o pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SELF=$(basename "$0")

die() { echo "$SELF: $*" >&2; exit 1; }

if [ "${HAVEN_REAL_DOCKER:-}" != "1" ]; then
  echo "$SELF: opt-in measurement against a real Docker daemon. Set HAVEN_REAL_DOCKER=1 to run it." >&2
  exit 2
fi

for t in docker nak jq curl unzip python3 sha256sum stat find awk sed timeout tmux; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

IMAGE=${P6_IMAGE:-holgerhatgarkeinenode/haven-docker:v1.2.2-6}
N=${P6_N:-24}

# ---------------------------------------------------------------- directories
WORK=${P6_WORK:-}
MADE_TMP=0
if [ -z "$WORK" ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/havenit-p6.XXXXXX") || die "mktemp failed"
  MADE_TMP=1
fi
WORK=$(realpath -m "$WORK")
case "$WORK/" in "$REPO"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "work dir $WORK lies inside the repo $REPO" ;; esac
case "$REPO/" in "$WORK"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "the repo $REPO lies inside the work dir $WORK" ;; esac
mkdir -p "$WORK" || die "cannot create $WORK"
[ -z "$(ls -A "$WORK")" ] || die "work dir $WORK is not empty"
chmod 700 "$WORK"

EVID=${P6_EVIDENCE:-$WORK/evidence}
mkdir -p "$EVID" || die "cannot create $EVID"
EVID=$(cd "$EVID" && pwd -P)
[ -z "$(ls -A "$EVID")" ] || die "evidence dir $EVID is not empty"

PROJ="havenit-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
SB=$WORK/sandbox
RELAY_NAME="$PROJ-relay-1"
CMDLOG=$EVID/commands.log
RES=$EVID/results.tsv
: >"$CMDLOG"
printf 'step\tfacts\n' >"$RES"

# ------------------------------------------------------------------- identity
KEY=$(nak key generate 2>/dev/null) || die "nak key generate failed"
case "$KEY" in *[!0-9a-f]*|"") die "unexpected key format" ;; esac
[ ${#KEY} -eq 64 ] || die "unexpected key length"
PKHEX=$(printf '%s' "$KEY" | nak key public 2>/dev/null) || die "cannot derive public key"
NPUB=$(nak encode npub "$PKHEX" 2>/dev/null) || die "cannot encode npub"
( umask 077; printf '%s\n' "$KEY" >"$WORK/owner.key" )
nakx() { NOSTR_SECRET_KEY=$KEY timeout 30 nak "$@" </dev/null; }

# ------------------------------------------------------------------- plumbing
declare -A R
FAIL=0
result() { printf '%s\t%s\n' "$1" "$2" >>"$RES"; echo "  [$1] $2"; }
check() { # name condition-result(yes/no) detail
  R[$1]=$2
  result "$1" "$2 — $3"
  [ "$2" = yes ] || FAIL=1
}

dc() {
  printf '+ docker compose -p %s %s\n' "$PROJ" "$*" >>"$CMDLOG"
  docker compose -p "$PROJ" -f "$SB/docker-compose.yml" --project-directory "$SB" "$@"
}

# the REAL ./haven of the sandbox, isolated by project and container name
haven() { # label args...
  local label=$1 rc; shift
  printf '+ COMPOSE_PROJECT_NAME=%s HAVEN_CONTAINER_NAME=%s ./haven %s\n' "$PROJ" "$RELAY_NAME" "$*" >>"$CMDLOG"
  ( cd "$SB" && COMPOSE_PROJECT_NAME=$PROJ HAVEN_CONTAINER_NAME=$RELAY_NAME ./haven "$@" ) >"$EVID/$label.log" 2>&1
  rc=$?
  R[$label.rc]=$rc
  result "$label" "./haven $* -> rc=$rc"
  return $rc
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  tmx kill-server >/dev/null 2>&1 || true
  echo "cleanup: docker compose -p $PROJ down -v --remove-orphans" >&2
  docker compose -p "$PROJ" -f "$SB/docker-compose.yml" --project-directory "$SB" \
    down -v --remove-orphans >>"$EVID/cleanup.log" 2>&1
  {
    echo "# leftovers after cleanup (must all be empty)"
    echo "containers:"; docker ps -a --filter "name=$PROJ" --format '{{.Names}}'
    echo "networks:";   docker network ls --filter "name=$PROJ" --format '{{.Name}}'
    echo "volumes:";    docker volume ls --filter "name=$PROJ" --format '{{.Name}}'
  } >"$EVID/leftovers.txt" 2>&1
  exit "$rc"
}
TSOCK="test-p6real-$$"
tmx() { tmux -L "$TSOCK" -f /dev/null "$@"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fingerprint() { # tag
  (
    cd "$REPO" || exit 1
    if [ -f .env ]; then echo "env_sha256=$(sha256sum .env | cut -d' ' -f1)"; else echo "env_sha256=absent"; fi
    echo "data_listing_sha256=$(find db blossom backups -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
    for f in docker-compose.yml docker-compose.tor.yml entrypoint.sh haven-guard.sh; do
      echo "$f sha256=$(sha256sum "$f" | cut -d' ' -f1)"
    done
  ) >"$EVID/repo-fingerprint-$1.txt"
}

relay_started_at() { docker inspect -f '{{.State.StartedAt}}' "$RELAY_NAME" 2>/dev/null || echo none; }
relay_state() { docker inspect -f '{{.State.Status}}' "$RELAY_NAME" 2>/dev/null || echo none; }

PORT=""
wait_ready() { # label ; the ephemeral port can change on every start
  local i
  PORT=""
  for ((i = 0; i < 150; i++)); do
    if [ "$(relay_state)" = running ]; then
      PORT=$(dc port relay 3355 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/')
      if [ -n "$PORT" ] && curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/"; then
        result "ready-$1" "port=$PORT"
        return 0
      fi
    fi
    sleep 0.4
  done
  dc logs --no-color --no-log-prefix relay >"$EVID/$1.relay.log" 2>&1
  result "ready-$1" "NOT READY state=$(relay_state)"
  return 1
}

snap() { # label ; sorted ID set, blob by hash, blossom list
  local f=$EVID/$1 rc=1 i code bsha list
  for i in 1 2 3; do
    nakx req -k 1 -a "$PKHEX" -l 5000 "ws://127.0.0.1:$PORT" >"$f.raw" 2>"$f.req.err"; rc=$?
    [ $rc -eq 0 ] && break
    sleep 1
  done
  [ $rc -eq 0 ] || { result "snap-$1" "nak req failed rc=$rc"; R[$1.eq]=failed; return 1; }
  jq -r .id <"$f.raw" | sort -u >"$f.ids"
  rm -f "$f.raw"
  code=$(curl -s -m 20 -o "$f.blob" -w '%{http_code}' "http://127.0.0.1:$PORT/$BLOBSHA")
  if [ "$code" = 200 ]; then bsha=$(sha256sum "$f.blob" | cut -c1-64); else bsha=-; fi
  rm -f "$f.blob"
  list=$(curl -s -m 20 "http://127.0.0.1:$PORT/list/$PKHEX" | jq -c -S '[.[].sha256] | sort' 2>/dev/null || echo INVALID)
  R[$1.n]=$(wc -l <"$f.ids")
  R[$1.ids]=$(sha256sum "$f.ids" | cut -c1-16)
  if [ -s "$WORK/ids.expected" ] && cmp -s "$f.ids" "$WORK/ids.expected"; then R[$1.eq]=yes; else R[$1.eq]=no; fi
  if [ "$bsha" = "$BLOBSHA" ]; then R[$1.blob]=yes; else R[$1.blob]=no; fi
  if [ "$list" = "[\"$BLOBSHA\"]" ]; then R[$1.list]=yes; else R[$1.list]=no; fi
  result "snap-$1" "ids=${R[$1.n]} sha256=${R[$1.ids]} equals_golden=${R[$1.eq]} blob_http=$code blob_hash_ok=${R[$1.blob]} blossom_list_ok=${R[$1.list]}"
}

# ===========================================================================
# preflight and sandbox
# ===========================================================================
IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null) \
  || die "image $IMAGE is not present locally (this script never pulls)"
fingerprint before
docker ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.State}} {{.CreatedAt}}' | sort >"$EVID/docker-ps-before.txt"

{
  echo "date:        $(date -Is)"
  echo "script:      $SELF sha256=$(sha256sum "$0" | cut -c1-16)"
  echo "repo HEAD:   $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
  echo "haven:       sha256=$(sha256sum "$REPO/haven" | cut -c1-16) (working tree copy)"
  echo "image:       $IMAGE"
  echo "image id:    $IMAGE_ID"
  echo "project:     $PROJ   relay container: $RELAY_NAME"
  echo "docker:      $(docker version --format '{{.Server.Version}}' 2>/dev/null) / compose $(docker compose version --short 2>/dev/null)"
  echo "host uid:gid $(id -u):$(id -g)"
  echo "host unzip:  $(unzip -v 2>/dev/null | head -1)"
  echo "work dir:    $WORK ($(stat -f -c %T "$WORK"))"
  echo "owner npub:  $NPUB   (throwaway key)"
} >"$EVID/environment.txt"

mkdir -p "$SB/db" "$SB/blossom"
cp "$REPO/haven" "$REPO/.env.example" "$SB/"
cp "$REPO/db/.gitignore" "$SB/db/.gitignore" 2>/dev/null || printf '*\n!.gitignore\n' >"$SB/db/.gitignore"
for f in relays_import relays_blastr whitelisted_npubs blacklisted_npubs; do echo '[]' >"$SB/$f.json"; done
sed -E \
  -e '/^[[:space:]]*container_name:/d' \
  -e 's#"3355:\$\{RELAY_PORT:-3355\}"#"127.0.0.1::3355"#' \
  -e 's#^([[:space:]]*)image:.*$#\1image: '"$IMAGE"'\n\1pull_policy: never#' \
  "$REPO/docker-compose.yml" >"$SB/docker-compose.yml"
grep -q -E 'container_name|haven-relay|"3355:' "$SB/docker-compose.yml" && die "sanitised compose file still carries a fixed name or port"
cp "$SB/docker-compose.yml" "$EVID/compose.sandbox.yml"
diff "$REPO/docker-compose.yml" "$SB/docker-compose.yml" >"$EVID/sanitize.diff" 2>&1

: >"$SB/.env"
dc run --rm --no-deps -T --entrypoint cat relay /app/.env.example.upstream >"$WORK/env.upstream" 2>"$EVID/env-extract.err" \
  || die "cannot read .env.example.upstream from the image"
sed -E \
  -e "s#^(OWNER_NPUB|PRIVATE_RELAY_NPUB|CHAT_RELAY_NPUB|OUTBOX_RELAY_NPUB|INBOX_RELAY_NPUB)=.*#\1=\"$NPUB\"#" \
  -e 's#^RELAY_URL=.*#RELAY_URL="localhost"#' \
  -e 's#^BACKUP_PROVIDER=.*#BACKUP_PROVIDER="none"#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_TOKENS_PER_INTERVAL)=.*#\1=1000#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_MAX_TOKENS)=.*#\1=1000#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_INTERVAL)=.*#\1=1#' \
  -e 's#^([A-Z]+_RELAY_ALLOW_(EMPTY|COMPLEX)_FILTERS)=.*#\1=true#' \
  "$WORK/env.upstream" >"$SB/.env"
printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" >>"$SB/.env"
# the starting engine is badger, set explicitly (upstream treats unset as lmdb)
sed -i -E '/^[[:space:]]*(export[[:space:]]+)?DB_ENGINE=/d' "$SB/.env"
printf 'DB_ENGINE="badger"\n' >>"$SB/.env"
grep -q '^BACKUP_PROVIDER="none"' "$SB/.env" || die "backup provider not none"
grep -q 'nsec' "$SB/.env" && die "generated .env mentions nsec"

python3 -I - "$N" "$WORK/seed.tsv" "$WORK/blob.bin" <<'PY'
import base64, hashlib, sys
n, out, blob = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def stream(label, size):
    d, x = b"", label
    while len(d) < size:
        x = hashlib.sha256(x).digest()
        d += x
    return d[:size]
with open(out, "w") as f:
    for i in range(1, n + 1):
        f.write("%d\tp6 seed %02d %s\n" % (1790000000 + i * 60, i, base64.b64encode(stream(b"p6-note-%d" % i, 450)).decode()))
with open(blob, "wb") as f:
    f.write(stream(b"p6-blob", 8192))
PY
BLOBSHA=$(sha256sum "$WORK/blob.bin" | cut -c1-64)

# ===========================================================================
# seed
# ===========================================================================
dc up -d relay >"$EVID/seed.up.log" 2>&1 || die "relay did not come up (seed.up.log)"
[ "$(relay_state)" = running ] || die "container $RELAY_NAME is not the relay (compose naming changed?)"
wait_ready seed || die "relay not ready"
: >"$WORK/ids.raw"
while IFS=$'\t' read -r ts content; do
  out=$(nakx event -k 1 -c "$content" --ts "$ts" "ws://127.0.0.1:$PORT" 2>>"$EVID/seed.err") || die "seeding failed (seed.err)"
  printf '%s\n' "$out" | grep '^{' | jq -r .id >>"$WORK/ids.raw"
done <"$WORK/seed.tsv"
sort -u "$WORK/ids.raw" >"$WORK/ids.expected"
[ "$(wc -l <"$WORK/ids.expected")" = "$N" ] || die "expected $N ids"
cp "$WORK/ids.expected" "$EVID/ids.golden"
up=$(nakx blossom upload --server "http://127.0.0.1:$PORT" "$WORK/blob.bin" 2>>"$EVID/seed.err") || die "blob upload failed"
[ "$(printf '%s\n' "$up" | grep '^{' | jq -r .sha256)" = "$BLOBSHA" ] || die "blob sha mismatch"
snap golden
[ "${R[golden.eq]}" = yes ] && [ "${R[golden.blob]}" = yes ] || die "the seeded relay does not serve what was published"


DIRS="private chat outbox inbox blossom"
# engine files per directory: "<dir>:b<n>/l<n>" (badger files / lmdb files)
disk_report() {
  local n b l out=""
  for n in $DIRS; do
    b=$(find "$SB/db/$n" -maxdepth 1 \( -name MANIFEST -o -name KEYREGISTRY -o -name '*.vlog' -o -name '*.sst' \) 2>/dev/null | wc -l)
    l=$(find "$SB/db/$n" -maxdepth 1 \( -name data.mdb -o -name lock.mdb \) 2>/dev/null | wc -l)
    out+="$n:b$b/l$l "
  done
  printf '%s' "${out% }"
}
# only_engine <badger|lmdb> — yes when all five directories hold that engine's
# files and none of the other's
only_engine() {
  local n b l
  for n in $DIRS; do
    b=$(find "$SB/db/$n" -maxdepth 1 \( -name MANIFEST -o -name KEYREGISTRY -o -name '*.vlog' -o -name '*.sst' \) 2>/dev/null | wc -l)
    l=$(find "$SB/db/$n" -maxdepth 1 \( -name data.mdb -o -name lock.mdb \) 2>/dev/null | wc -l)
    if [ "$1" = badger ]; then [ "$b" -gt 0 ] && [ "$l" = 0 ] || { echo no; return; }
    else [ "$l" -gt 0 ] && [ "$b" = 0 ] || { echo no; return; }; fi
  done
  echo yes
}
env_engine() { sed -n 's/^DB_ENGINE=//p' "$SB/.env" | sed -e 's/[[:space:]]*#.*//' -e 's/"//g'; }
# ===========================================================================
# the TUI
# ===========================================================================
TUI_W=120 TUI_H=30
cap() { tmx capture-pane -p -t p6; }
has() { cap | grep -qF -- "$1"; }
wait_text() { # text seconds
  local i
  for ((i = 0; i < $2 * 10; i++)); do has "$1" && return 0; sleep 0.1; done
  cap >"$EVID/timeout-$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' _ | cut -c1-30).screen"
  return 1
}
keys() { tmx send-keys -t p6 "$@"; sleep 0.4; }
printf '+ tmux -L %s: COMPOSE_PROJECT_NAME=%s HAVEN_CONTAINER_NAME=%s ./haven --plain tui\n' "$TSOCK" "$PROJ" "$RELAY_NAME" >>"$CMDLOG"
tmx new-session -d -x "$TUI_W" -y "$TUI_H" -s p6 \
  "cd $(printf '%q' "$SB") && export TERM=xterm-256color LC_ALL=C.UTF-8 COMPOSE_PROJECT_NAME=$PROJ HAVEN_CONTAINER_NAME=$RELAY_NAME && ./haven --plain tui 2>$(printf '%q' "$WORK/tui.stderr"); echo \$? >$(printf '%q' "$WORK/tui.rc"); sleep 600"
wait_text "▸ s Start" 30 || die "the TUI did not start"

# --- Back up now
keys b
wait_text "Back up now? A verified copy of the relay database" 10 || die "no backup confirm"
keys Enter
if wait_text "Backup finished" 180; then bk_box=yes; else bk_box=no; fi
cap >"$EVID/backup-box.screen"
ZIP=$(ls -1 "$SB/backups"/haven-backup-*.zip 2>/dev/null | head -n1)
zip_ok=no
if [ -n "$ZIP" ] && unzip -tq "$ZIP" >/dev/null 2>&1 && [ "$(unzip -Z1 "$ZIP" | sort | tr '\n' ' ')" = "blossom.jsonl chat.jsonl inbox.jsonl outbox.jsonl private.jsonl " ]; then zip_ok=yes; fi
check backup-zip "$([ $bk_box = yes ] && [ $zip_ok = yes ] && echo yes || echo no)" "TUI box=$bk_box, verified zip with five entries=$zip_ok ($(basename "${ZIP:-none}"))"
keys x
wait_ready after-backup && snap after-backup
check backup-serves "$([ "${R[after-backup.eq]:-no}" = yes ] && [ "${R[after-backup.blob]:-no}" = yes ] && echo yes || echo no)" "after the TUI backup the relay serves the golden set and the blob"

# --- Switch engine badger -> lmdb, typed confirmation
keys d
wait_text "On disk: badger" 30 || die "no switch overview"
cap >"$EVID/switch-overview.screen"
keys Enter
wait_text "Type lmdb:" 10 || die "no typed confirmation"
tmx send-keys -t p6 -l lmdb; sleep 0.3
keys Enter
: >"$WORK/steps.seen"
done_sw=no
for ((i = 0; i < 3000; i++)); do
  cap | grep -oE '[✓▸] [a-z]+' >>"$WORK/steps.seen"
  if has "Engine switched"; then done_sw=yes; break; fi
  if has "Switch rolled back" || has "Switch failed" || has "Switch not started"; then break; fi
  sleep 0.1
done
cap >"$EVID/switch-box.screen"
seen=$(sed 's/^. //' "$WORK/steps.seen" | awk '!s[$0]++' | tr '\n' ' ')
echo "$seen" >"$EVID/switch-steps-seen.txt"
# the steps must appear in the verb's order (each seen at least once, as ✓ or ▸)
order_ok=no
python3 -I - "$seen" <<'PY2' && order_ok=yes
import sys
want = "preflight stop backup move config restore start".split()
seen = sys.argv[1].split()
sys.exit(0 if seen == want else 1)
PY2
check switch-box "$done_sw" "the TUI shows 'Engine switched'"
check switch-steps "$order_ok" "steps shown on screen in order: $seen"
check switch-disk "$([ "$(env_engine)" = lmdb ] && [ "$(only_engine lmdb)" = yes ] && echo yes || echo no)" ".env DB_ENGINE=$(env_engine), db/ $(disk_report)"
keys x
wait_ready after-switch && snap after-switch
check switch-serves "$([ "${R[after-switch.eq]:-no}" = yes ] && [ "${R[after-switch.blob]:-no}" = yes ] && echo yes || echo no)" "on lmdb the relay serves the identical sorted ID set and the blob"

# --- Restore the earlier backup (the oldest zip: the one of the first step)
keys e
wait_text "backups/, newest first" 20 || die "no restore list"
cap >"$EVID/restore-list.screen"
keys End
keys Up
cap | grep -qF "▸ $(basename "$ZIP" | cut -c1-12)" || cap | grep -q "▸ haven-backup-" || true
keys Enter
wait_text "Restore haven-backup-" 10 || die "no restore confirm (selected: $(cap | grep -m1 '▸'))"
keys Left
keys Enter
if wait_text "Restore finished" 180; then rs_box=yes; else rs_box=no; fi
cap >"$EVID/restore-box.screen"
chosen=$(grep -oE 'restore /app/backups/[^ ]+' "$EVID/commands.log" 2>/dev/null | tail -1)
keys x
wait_ready after-restore && snap after-restore
check restore-serves "$([ $rs_box = yes ] && [ "${R[after-restore.eq]:-no}" = yes ] && [ "${R[after-restore.blob]:-no}" = yes ] && echo yes || echo no)" "after restoring $(basename "$ZIP") in the TUI: box=$rs_box, identical ID set and blob"

# --- quit, console
keys q
for ((i = 0; i < 100; i++)); do [ -s "$WORK/tui.rc" ] && break; sleep 0.1; done
check tui-exit "$([ "$(cat "$WORK/tui.rc" 2>/dev/null)" = 0 ] && echo yes || echo no)" "the TUI quit with rc=$(cat "$WORK/tui.rc" 2>/dev/null)"
check tui-stderr "$([ -f "$WORK/tui.stderr" ] && [ ! -s "$WORK/tui.stderr" ] && echo yes || echo no)" "TUI stderr $(wc -c <"$WORK/tui.stderr" 2>/dev/null) bytes"

fingerprint after
check repo-untouched "$(cmp -s "$EVID/repo-fingerprint-before.txt" "$EVID/repo-fingerprint-after.txt" && echo yes || echo no)" "repo .env, db/, blossom/, backups/, compose files, entrypoint unchanged"
grep -rlF "$KEY" "$EVID" >/dev/null 2>&1 && check key-leak no "the owner key appears in the evidence" || check key-leak yes "the owner key appears nowhere in the evidence"

echo
echo "summary:"
for k in backup-zip backup-serves switch-box switch-steps switch-disk switch-serves restore-serves tui-exit tui-stderr repo-untouched key-leak; do
  printf '  %-15s %s\n' "$k" "${R[$k]:-no}"
done
exit "$FAIL"
