#!/usr/bin/env bash
# P2 measurement: the REAL `./haven backup` and `./haven restore` against the
# published image, run from a sandbox copy of the repo.
#
# OPT-IN. Not a bats test; needs a running Docker daemon and the image already
# present locally (it never pulls).
#
#   HAVEN_REAL_DOCKER=1 \
#   [P2_EVIDENCE=<empty dir for the evidence files>] \
#   [P2_WORK=<empty work dir outside the repo>] \
#   [P2_IMAGE=holgerhatgarkeinenode/haven-docker:v1.2.2-6] \
#   [P2_N=24] \
#     tests/real-docker/p2-backup-restore.sh
#
# ISOLATION (same pattern as p1-engine-switch.sh; the script refuses otherwise):
#   - own work dir, refused when it lies inside the repo (or the repo inside it)
#   - sandbox = copy of ./haven plus the repo's docker-compose.yml, sanitised:
#     no container_name, port 127.0.0.1::3355 (ephemeral), pull_policy: never
#   - own compose project `havenit-<random>`, handed to ./haven through
#     COMPOSE_PROJECT_NAME (read by docker compose itself; ./haven has no seam
#     for it and needs none); the relay container name through the existing
#     HAVEN_CONTAINER_NAME seam; --plain so a host `haven-tor` cannot pick mode
#   - throwaway owner key (nak), 0600 file in the work dir, evidence scanned for it
#   - cleanup `docker compose -p <project> down -v --remove-orphans` in a trap;
#     nothing is stopped or removed by container name
#   - the repo's db/, blossom/ and .env are only fingerprinted, before and after
#
# STEPS
#   seed     relay up, N kind-1 notes + one blob over the wire, golden ID set
#   backup   ./haven backup p2.zip with the relay running (host unzip verifies);
#            backups/ created 0700, the zip 0600 (umask 077 in the container)
#   sigterm  ./haven backup sig.zip, SIGTERM to ./haven while the one-shot
#            container exists: what the trap does with compose run -T (relay
#            restarted? one-shot container gone?)
#   image    ./haven backup p2-image.zip with no host unzip (image unzip verifies)
#   damaged  ./haven restore of a 1-byte-truncated and a byte-flipped copy, with
#            the image's unzip only: both refused, relay not restarted
#   empty    stop relay, move db/<name> aside (blossom/ stays), start: serves 0
#   restore  ./haven restore p2.zip --yes into the emptied db: same ID set, blob
#   confirm  ./haven restore p2.zip without tty and without --yes: refused,
#            relay not restarted

set -u
set -o pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SELF=$(basename "$0")

die() { echo "$SELF: $*" >&2; exit 1; }

if [ "${HAVEN_REAL_DOCKER:-}" != "1" ]; then
  echo "$SELF: opt-in measurement against a real Docker daemon. Set HAVEN_REAL_DOCKER=1 to run it." >&2
  exit 2
fi

for t in docker nak jq curl unzip python3 sha256sum stat find awk sed timeout; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

IMAGE=${P2_IMAGE:-holgerhatgarkeinenode/haven-docker:v1.2.2-6}
N=${P2_N:-24}

# ---------------------------------------------------------------- directories
WORK=${P2_WORK:-}
MADE_TMP=0
if [ -z "$WORK" ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/havenit-p2.XXXXXX") || die "mktemp failed"
  MADE_TMP=1
fi
WORK=$(realpath -m "$WORK")
case "$WORK/" in "$REPO"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "work dir $WORK lies inside the repo $REPO" ;; esac
case "$REPO/" in "$WORK"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "the repo $REPO lies inside the work dir $WORK" ;; esac
mkdir -p "$WORK" || die "cannot create $WORK"
[ -z "$(ls -A "$WORK")" ] || die "work dir $WORK is not empty"
chmod 700 "$WORK"

EVID=${P2_EVIDENCE:-$WORK/evidence}
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
cp "$REPO/haven" "$SB/haven"
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
        f.write("%d\tp2 seed %02d %s\n" % (1790000000 + i * 60, i, base64.b64encode(stream(b"p2-note-%d" % i, 450)).decode()))
with open(blob, "wb") as f:
    f.write(stream(b"p2-blob", 8192))
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

# ===========================================================================
# backup with the relay running (host unzip)
# ===========================================================================
t0=$(relay_started_at)
haven backup --plain backup p2.zip
Z=$SB/backups/p2.zip
check backup-rc "$( [ "${R[backup.rc]}" = 0 ] && echo yes || echo no)" "rc=${R[backup.rc]}"
check backup-verified-host "$(grep -q 'five entries verified with host unzip' "$EVID/backup.log" && echo yes || echo no)" "$(grep -o 'Backup written: .*' "$EVID/backup.log" | sed "s#$SB/##")"
unzip -Z1 "$Z" 2>/dev/null | sort >"$EVID/p2.entries"
unzip -v "$Z" >"$EVID/p2.unzip-v.txt" 2>&1
unzip -t "$Z" >"$EVID/p2.unzip-t.txt" 2>&1; ut=$?
check zip-five-entries "$( [ "$(tr '\n' ' ' <"$EVID/p2.entries")" = "blossom.jsonl chat.jsonl inbox.jsonl outbox.jsonl private.jsonl " ] && echo yes || echo no)" "entries: $(tr '\n' ' ' <"$EVID/p2.entries")"
check zip-unzip-t "$( [ $ut = 0 ] && echo yes || echo no)" "host unzip -t rc=$ut"
own=$(stat -c '%u:%g' "$Z")
check zip-host-owner "$( [ "$own" = "$(id -u):$(id -g)" ] && echo yes || echo no)" "zip owner $own, host $(id -u):$(id -g); $(stat -c '%a %s' "$Z") (mode, bytes)"
zmode=$(stat -c %a "$Z"); bmode=$(stat -c %a "$SB/backups")
check zip-mode-600 "$( [ "$zmode" = 600 ] && echo yes || echo no)" "zip mode $zmode"
check backups-mode-700 "$( [ "$bmode" = 700 ] && echo yes || echo no)" "backups/ mode $bmode (created by ./haven)"
check zip-no-partial "$( [ -z "$(find "$SB/backups" -name '*.partial*' -print -quit)" ] && echo yes || echo no)" "$(find "$SB/backups" -mindepth 1 -printf '%f ')"
t1=$(relay_started_at)
check backup-relay-restarted "$( [ "$t0" != "$t1" ] && [ "$(relay_state)" = running ] && echo yes || echo no)" "StartedAt before=$t0 after=$t1 state=$(relay_state)"
wait_ready after-backup && snap after-backup
check backup-relay-serves "${R[after-backup.eq]:-no}" "after the backup the restarted relay serves the golden set"

# ===========================================================================
# SIGTERM to ./haven backup while the one-shot container runs
# ===========================================================================
ONESHOT="$RELAY_NAME-oneshot"
oneshot_present() { docker ps -a --format '{{.Names}}' | grep -qxF -- "$ONESHOT"; }
sig_landed=no
for attempt in 1 2 3; do
  [ "$(relay_state)" = running ] || wait_ready "before-sigterm-$attempt"
  t8=$(relay_started_at)
  printf '+ COMPOSE_PROJECT_NAME=%s HAVEN_CONTAINER_NAME=%s ./haven --plain backup sig%s.zip & ; kill -TERM <pid> once %s exists\n' "$PROJ" "$RELAY_NAME" "$attempt" "$ONESHOT" >>"$CMDLOG"
  ( cd "$SB" && COMPOSE_PROJECT_NAME=$PROJ HAVEN_CONTAINER_NAME=$RELAY_NAME exec ./haven --plain backup "sig$attempt.zip" ) >"$EVID/sigterm-$attempt.log" 2>&1 &
  hp=$!
  seen=no
  for ((i = 0; i < 600; i++)); do
    if oneshot_present; then seen=yes; break; fi
    kill -0 "$hp" 2>/dev/null || break
    sleep 0.05
  done
  [ "$seen" = yes ] && kill -TERM "$hp"
  wait "$hp"; sig_rc=$?
  result "sigterm-$attempt" "one-shot seen=$seen, ./haven rc=$sig_rc"
  if [ "$seen" = yes ] && grep -q 'Received SIGTERM during the backup' "$EVID/sigterm-$attempt.log"; then
    sig_landed=yes
    break
  fi
done
sleep 1
t9=$(relay_started_at)
check sigterm-landed "$sig_landed" "SIGTERM reached ./haven while $ONESHOT existed (attempt $attempt); ./haven rc=$sig_rc"
check sigterm-exit-143 "$( [ "$sig_rc" = 143 ] && echo yes || echo no)" "./haven re-raised the signal: rc=$sig_rc"
check sigterm-relay-restarted "$( [ "$(relay_state)" = running ] && [ "$t8" != "$t9" ] && echo yes || echo no)" "relay state=$(relay_state), StartedAt before=$t8 after=$t9; ./haven said: $(grep -oE 'The relay is (running|NOT running)' "$EVID/sigterm-$attempt.log" | tail -n1)"
check sigterm-oneshot-gone "$( ! oneshot_present && echo yes || echo no)" "docker ps -a lists $ONESHOT: $(oneshot_present && echo yes || echo no)"
result sigterm-files "backups/ after the interrupted run: $(find "$SB/backups" -mindepth 1 -printf '%f ')"
wait_ready after-sigterm

# ===========================================================================
# backup verified by the image's unzip (no host unzip)
# ===========================================================================
HAVEN_HOST_UNZIP=no-such-unzip-p2 haven backup-image --plain backup p2-image.zip
check image-backup-verified "$( [ "${R[backup-image.rc]}" = 0 ] && grep -q "verified with the image's unzip" "$EVID/backup-image.log" && [ "$(stat -c %a "$SB/backups/p2-image.zip")" = 600 ] && echo yes || echo no)" "rc=${R[backup-image.rc]}; mode $(stat -c %a "$SB/backups/p2-image.zip" 2>/dev/null); $(grep -o 'Backup written: .*' "$EVID/backup-image.log" | sed "s#$SB/##")"
wait_ready after-image-backup

# ===========================================================================
# damaged copies, image unzip only: refused before the relay is touched
# ===========================================================================
sz=$(stat -c %s "$Z")
head -c $((sz - 1)) "$Z" >"$SB/backups/cut1.zip"
python3 -I - "$Z" "$SB/backups/flip.zip" <<'PY'
import shutil, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
shutil.copy(src, dst)
zi = zipfile.ZipFile(src).getinfo("outbox.jsonl")
pos = zi.header_offset + 30 + len(zi.filename.encode()) + len(zi.extra) + zi.compress_size // 2
with open(dst, "r+b") as f:
    f.seek(pos); b = f.read(1); f.seek(pos); f.write(bytes([b[0] ^ 0xFF]))
PY
t2=$(relay_started_at)
HAVEN_HOST_UNZIP=no-such-unzip-p2 haven restore-cut1 --plain restore cut1.zip --yes
HAVEN_HOST_UNZIP=no-such-unzip-p2 haven restore-flip --plain restore flip.zip --yes
t3=$(relay_started_at)
check damaged-refused "$( [ "${R[restore-cut1.rc]}" != 0 ] && [ "${R[restore-flip.rc]}" != 0 ] && [ "$t2" = "$t3" ] && echo yes || echo no)" "cut by 1 byte: rc=${R[restore-cut1.rc]} ($(grep -o 'is damaged: [^.]*' "$EVID/restore-cut1.log" | head -1)); flipped byte: rc=${R[restore-flip.rc]} ($(grep -o 'is damaged: [^.]*' "$EVID/restore-flip.log" | head -1)); relay StartedAt unchanged: $( [ "$t2" = "$t3" ] && echo yes || echo no)"

# ===========================================================================
# empty database, then restore
# ===========================================================================
dc stop -t 30 relay >"$EVID/empty.stop.log" 2>&1
mkdir -p "$WORK/db-aside"
for d in "$SB"/db/*; do [ -e "$d" ] && mv "$d" "$WORK/db-aside/"; done
ls -A "$SB/db" >"$EVID/db-emptied.txt"
dc start relay >>"$EVID/empty.stop.log" 2>&1
wait_ready emptied && snap emptied
check emptied-serves-nothing "$( [ "${R[emptied.n]:-x}" = 0 ] && echo yes || echo no)" "negative control: the emptied db serves ${R[emptied.n]:-?} events (blob file still in blossom/: list_ok=${R[emptied.list]:-?})"

t4=$(relay_started_at)
haven restore --plain restore p2.zip --yes
t5=$(relay_started_at)
check restore-rc "$( [ "${R[restore.rc]}" = 0 ] && grep -q 'Restore finished' "$EVID/restore.log" && echo yes || echo no)" "rc=${R[restore.rc]}; relay restarted: $( [ "$t4" != "$t5" ] && echo yes || echo no)"
wait_ready after-restore && snap after-restore
check restore-same-ids "${R[after-restore.eq]:-no}" "sorted ID set after the restore: ${R[after-restore.n]:-?} ids sha256=${R[after-restore.ids]:-?} vs golden ${R[golden.ids]}"
check restore-blob "$( [ "${R[after-restore.blob]:-no}" = yes ] && [ "${R[after-restore.list]:-no}" = yes ] && echo yes || echo no)" "blob fetched by hash: ${R[after-restore.blob]:-?}; blossom list: ${R[after-restore.list]:-?}"

# ===========================================================================
# confirmation gate: non-empty db, no tty, no --yes
# ===========================================================================
t6=$(relay_started_at)
haven confirm --plain restore p2.zip </dev/null
t7=$(relay_started_at)
check confirm-refused "$( [ "${R[confirm.rc]}" != 0 ] && [ "$t6" = "$t7" ] && grep -q -- '--yes' "$EVID/confirm.log" && echo yes || echo no)" "rc=${R[confirm.rc]}; relay StartedAt unchanged: $( [ "$t6" = "$t7" ] && echo yes || echo no)"

# ===========================================================================
# closing checks
# ===========================================================================
ls -la "$SB/backups" | sed "s#$SB/##" >"$EVID/backups-ls.txt"
fingerprint after
check repo-fingerprint "$(cmp -s "$EVID/repo-fingerprint-before.txt" "$EVID/repo-fingerprint-after.txt" && echo yes || echo no)" "repo .env hash, db/ blossom/ backups/ listing, compose files unchanged"
docker compose -p "$PROJ" -f "$SB/docker-compose.yml" --project-directory "$SB" down -v --remove-orphans >>"$EVID/cleanup.log" 2>&1
docker ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.State}} {{.CreatedAt}}' | sort >"$EVID/docker-ps-after.txt"
diff <(grep -v " $PROJ" "$EVID/docker-ps-before.txt") <(grep -v " $PROJ" "$EVID/docker-ps-after.txt") >"$EVID/docker-ps.diff"
check other-containers-untouched "$( [ ! -s "$EVID/docker-ps.diff" ] && echo yes || echo no)" "docker ps -a rows outside $PROJ identical (ID, name, state, creation)"
left=$( { docker ps -a --filter "name=$PROJ" -q; docker network ls --filter "name=$PROJ" -q; docker volume ls --filter "name=$PROJ" -q; } | wc -l)
check no-leftovers "$( [ "$left" = 0 ] && echo yes || echo no)" "$PROJ containers/networks/volumes after down: $left"

printf 'canary %s\n' "$KEY" >"$WORK/canary.txt"
canary=$(grep -rIl -e "$KEY" "$WORK/canary.txt" | wc -l)
hits=$(grep -rIl -e "$KEY" -e 'nsec1[0-9a-z]\{20,\}' "$EVID" 2>/dev/null | wc -l)
check key-scan "$( [ "$hits" = 0 ] && [ "$canary" = 1 ] && echo yes || echo no)" "evidence files with the owner key or an nsec: $hits (positive control finds the canary: $canary)"

result elapsed "whole run ${SECONDS}s"
echo
echo "=== results.tsv"; cat "$RES"
echo "evidence: $EVID"
exit "$FAIL"
