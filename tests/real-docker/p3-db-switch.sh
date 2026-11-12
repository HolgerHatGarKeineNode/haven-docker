#!/usr/bin/env bash
# P3 measurement: the REAL `./haven db-switch` against the published image, run
# from a sandbox copy of the repo.
#
# OPT-IN. Not a bats test; needs a running Docker daemon and the image already
# present locally (it never pulls).
#
#   HAVEN_REAL_DOCKER=1 \
#   [P3_EVIDENCE=<empty dir for the evidence files>] \
#   [P3_WORK=<empty work dir outside the repo>] \
#   [P3_IMAGE=holgerhatgarkeinenode/haven-docker:v1.2.2-6] \
#   [P3_N=24] \
#     tests/real-docker/p3-db-switch.sh
#
# ISOLATION (same pattern as p2-backup-restore.sh; the script refuses otherwise):
#   - own work dir, refused when it lies inside the repo (or the repo inside it)
#   - sandbox = copy of ./haven plus the repo's docker-compose.yml, sanitised:
#     no container_name, port 127.0.0.1::3355 (ephemeral), pull_policy: never
#   - own compose project `havenit-<random>` (COMPOSE_PROJECT_NAME), the relay
#     container name through the HAVEN_CONTAINER_NAME seam, --plain
#   - throwaway owner key (nak), 0600 file in the work dir, evidence scanned for it
#   - cleanup `docker compose -p <project> down -v --remove-orphans` in a trap;
#     nothing is stopped or removed by container name
#   - the repo's db/, blossom/ and .env are only fingerprinted, before and after
#
# STEPS (every "serves" row compares the sorted event-ID set with the golden
# set and fetches the blob by hash; counts alone are never a verdict)
#   seed       relay up on badger, N kind-1 notes + one blob, golden ID set
#   to-lmdb    ./haven db-switch lmdb --yes with the relay running
#   to-badger  ./haven db-switch badger --yes (lmdb -> badger)
#   undo       ./haven db-switch --rollback --yes: undoes to-badger (back on lmdb)
#   fail       ./haven db-switch badger --yes whose pre-switch zip gets one byte
#              flipped right before the restore (test hook HAVEN_TEST_SWITCH_HOOK
#              at before-restore, after the script's own verification): the
#              restore must fail and the switch roll back to lmdb
#   fail-late  ./haven db-switch badger --yes, hook fails after a complete
#              restore: the restored badger database is set aside, lmdb back
#   rep-*      the reporter's state of issue #15: badger with the golden set,
#              DB_ENGINE flipped to lmdb by hand and the relay started with
#              plain compose (served: 0, all five directories mixed), one more
#              event published on lmdb; then ./haven start on it (goes ahead,
#              one warning), db-switch lmdb --from badger (golden set, the
#              extra event not served), --rollback (mixed layout and lmdb back:
#              the extra event is served again, so it was kept), and the R3
#              arm: badger only, DB_ENGINE flipped, relay never started —
#              ./haven start refuses, db-switch lmdb serves the golden set

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

IMAGE=${P3_IMAGE:-holgerhatgarkeinenode/haven-docker:v1.2.2-6}
N=${P3_N:-24}

# ---------------------------------------------------------------- directories
WORK=${P3_WORK:-}
MADE_TMP=0
if [ -z "$WORK" ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/havenit-p3.XXXXXX") || die "mktemp failed"
  MADE_TMP=1
fi
WORK=$(realpath -m "$WORK")
case "$WORK/" in "$REPO"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "work dir $WORK lies inside the repo $REPO" ;; esac
case "$REPO/" in "$WORK"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "the repo $REPO lies inside the work dir $WORK" ;; esac
mkdir -p "$WORK" || die "cannot create $WORK"
[ -z "$(ls -A "$WORK")" ] || die "work dir $WORK is not empty"
chmod 700 "$WORK"

EVID=${P3_EVIDENCE:-$WORK/evidence}
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
  # the media index in numbers: entries for the blob, and all entries
  R[$1.listn]=$(jq -r --arg s "$BLOBSHA" '[.[] | select(. == $s)] | length' <<<"$list" 2>/dev/null || echo INVALID)
  R[$1.listt]=$(jq -r 'length' <<<"$list" 2>/dev/null || echo INVALID)
  result "snap-$1" "ids=${R[$1.n]} sha256=${R[$1.ids]} equals_golden=${R[$1.eq]} blob_http=$code blob_hash_ok=${R[$1.blob]} blossom_list_ok=${R[$1.list]}"
}

# list_row <row> <snap label> <entries> <why> — the Blossom list after an arm
# holds exactly <entries> entries, all for the seeded blob. The expectation is
# measured (2026-11-12, v1.2.2-6): a restore into an empty database (and every
# db-switch, which restores into one) lists the blob once; on badger a restore
# into a database that already lists it adds nothing; on lmdb it adds one more
# identical entry per restore. Notes are never doubled (the serves rows).
list_row() {
  check "$1" "$( [ "${R[$2.listn]:-x}" = "$3" ] && [ "${R[$2.listt]:-x}" = "$3" ] && echo yes || echo no)" "/list after $2: ${R[$2.listn]:-?} entries for the blob, ${R[$2.listt]:-?} in all (want $3: $4)"
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
        f.write("%d\tp3 seed %02d %s\n" % (1790000000 + i * 60, i, base64.b64encode(stream(b"p3-note-%d" % i, 450)).decode()))
with open(blob, "wb") as f:
    f.write(stream(b"p3-blob", 8192))
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
# helpers for the engine checks
# ===========================================================================
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
crc_list() { unzip -v "$1" 2>/dev/null | awk 'NF >= 8 && $7 ~ /^[0-9a-f]{8}$/ {print $8, $7}' | LC_ALL=C sort; }
yn() { if "$@"; then echo yes; else echo no; fi; }
marker_absent() { [ ! -e "$SB/db/.switch-in-progress" ] && [ -f "$SB/db/.gitignore" ]; }
newest() { ls -1t $1 2>/dev/null | head -n1; }

# switch_checks <label> <engine> — the rows every completed switch must pass
switch_checks() {
  local label=$1 e=$2 pre post t
  ls -laR "$SB/db" | sed "s#$SB/##" >"$EVID/$label.db-ls.txt"
  check "$label-rc" "$( [ "${R[$label.rc]}" = 0 ] && grep -qx '::result ok' "$EVID/$label.log" && echo yes || echo no)" "rc=${R[$label.rc]}, $(grep -E '^::result' "$EVID/$label.log")"
  check "$label-env" "$( [ "$(env_engine)" = "$e" ] && echo yes || echo no)" "DB_ENGINE in .env: $(env_engine)"
  check "$label-disk" "$( [ "$(only_engine "$e")" = yes ] && marker_absent && echo yes || echo no)" "$(disk_report); marker gone, db/.gitignore kept: $(yn marker_absent)"
  pre=$(newest "$SB/backups/haven-pre-switch-$e-*.zip"); post=$(newest "$SB/backups/haven-post-switch-$e-*.zip")
  crc_list "$pre" >"$EVID/$label.pre.crc"; crc_list "$post" >"$EVID/$label.post.crc"
  check "$label-crc" "$( [ "$(wc -l <"$EVID/$label.pre.crc")" = 5 ] && cmp -s "$EVID/$label.pre.crc" "$EVID/$label.post.crc" && echo yes || echo no)" "per-entry CRC32 of ${pre##*/} and ${post##*/}: $(tr '\n' ' ' <"$EVID/$label.pre.crc")"
  wait_ready "$label" && snap "$label"
  check "$label-serves" "$( [ "${R[$label.eq]:-no}" = yes ] && [ "${R[$label.blob]:-no}" = yes ] && echo yes || echo no)" "sorted ID set equals golden: ${R[$label.eq]:-?} (${R[$label.n]:-?} ids sha256=${R[$label.ids]:-?}); blob by hash: ${R[$label.blob]:-?}"
  list_row "$label-list" "$label" 1 "a switch restores into an empty $e database"
}

# ===========================================================================
# badger -> lmdb with the relay running
# ===========================================================================
t0=$(relay_started_at)
haven to-lmdb --plain db-switch lmdb --yes
switch_checks to-lmdb lmdb
check to-lmdb-old-kept "$( [ -n "$(find "$SB/db" -maxdepth 2 -path "$SB/db/.pre-switch-badger-*/private" -print -quit)" ] && echo yes || echo no)" "$(cd "$SB/db" && ls -d .pre-switch-* 2>/dev/null | tr '\n' ' ')"
check to-lmdb-relay-restarted "$( [ "$t0" != "$(relay_started_at)" ] && [ "$(relay_state)" = running ] && echo yes || echo no)" "StartedAt before=$t0 after=$(relay_started_at)"
sleep 1

# ===========================================================================
# lmdb -> badger
# ===========================================================================
haven to-badger --plain db-switch badger --yes
switch_checks to-badger badger
sleep 1

# ===========================================================================
# --rollback after a completed switch: undoes to-badger, back on lmdb
# ===========================================================================
haven undo --plain db-switch --rollback --yes
ls -laR "$SB/db" | sed "s#$SB/##" >"$EVID/undo.db-ls.txt"
check undo-rc "$( [ "${R[undo.rc]}" = 0 ] && grep -qx '::result rolled-back' "$EVID/undo.log" && echo yes || echo no)" "rc=${R[undo.rc]}, $(grep -E '^::result' "$EVID/undo.log")"
check undo-env-disk "$( [ "$(env_engine)" = lmdb ] && [ "$(only_engine lmdb)" = yes ] && marker_absent && echo yes || echo no)" "DB_ENGINE=$(env_engine); $(disk_report)"
post_dir=$(newest "-d $SB/db/.post-switch-badger-*")
check undo-post-kept "$( [ -n "$post_dir" ] && [ -f "$post_dir/private/MANIFEST" ] && echo yes || echo no)" "set aside: ${post_dir#"$SB/"}"
wait_ready undo && snap undo
check undo-serves "$( [ "${R[undo.eq]:-no}" = yes ] && [ "${R[undo.blob]:-no}" = yes ] && echo yes || echo no)" "sorted ID set equals golden: ${R[undo.eq]:-?} (${R[undo.n]:-?} ids); blob by hash: ${R[undo.blob]:-?}"
list_row undo-list undo 1 "the undo puts the earlier directories back, which listed it once"
sleep 1

# ===========================================================================
# a switch whose restore fails: one byte of the pre-switch zip flipped right
# before the restore one-shot (after the script's own verification)
# ===========================================================================
cat >"$WORK/hook-flip.sh" <<HOOK
#!/usr/bin/env bash
[ "\$1" = before-restore ] || exit 0
z=\$(ls -1t "$SB"/backups/haven-pre-switch-badger-*.zip | head -n1)
echo "flip \$z" >>"$WORK/hook.log"
exec python3 -I "$WORK/flip.py" "\$z"
HOOK
cat >"$WORK/flip.py" <<'PY'
import sys, zipfile
p = sys.argv[1]
zi = max(zipfile.ZipFile(p).infolist(), key=lambda i: i.compress_size)
pos = zi.header_offset + 30 + len(zi.filename.encode()) + len(zi.extra) + zi.compress_size // 2
with open(p, "r+b") as f:
    f.seek(pos); b = f.read(1); f.seek(pos); f.write(bytes([b[0] ^ 0xFF]))
print(zi.filename, pos)
PY
chmod 700 "$WORK/hook-flip.sh"
t4=$(relay_started_at)
HAVEN_TEST_SWITCH_HOOK="$WORK/hook-flip.sh" haven fail --plain db-switch badger --yes
ls -laR "$SB/db" | sed "s#$SB/##" >"$EVID/fail.db-ls.txt"
cp "$WORK/hook.log" "$EVID/fail.hook.log" 2>/dev/null
check fail-rolled-back "$( [ "${R[fail.rc]}" != 0 ] && grep -qx '::result rolled-back' "$EVID/fail.log" && echo yes || echo no)" "rc=${R[fail.rc]}, $(grep -E '^::result' "$EVID/fail.log"); hook: $(sed "s#$SB/##" "$WORK/hook.log" 2>/dev/null); reason: $(grep -o 'The engine switch failed: .*' "$EVID/fail.log")"
check fail-env-disk "$( [ "$(env_engine)" = lmdb ] && [ "$(only_engine lmdb)" = yes ] && marker_absent && echo yes || echo no)" "DB_ENGINE=$(env_engine); $(disk_report)"
failed_dir=$(newest "-d $SB/db/.failed-*")
check fail-partial-kept "$( [ -n "$failed_dir" ] && echo yes || echo no)" "set aside: ${failed_dir#"$SB/"} ($(cd "$failed_dir" 2>/dev/null && find . -maxdepth 2 -type f | sort | tr '\n' ' '))"
check fail-relay-restarted "$( [ "$t4" != "$(relay_started_at)" ] && [ "$(relay_state)" = running ] && echo yes || echo no)" "StartedAt before=$t4 after=$(relay_started_at)"
wait_ready fail && snap fail
check fail-serves "$( [ "${R[fail.eq]:-no}" = yes ] && [ "${R[fail.blob]:-no}" = yes ] && echo yes || echo no)" "sorted ID set equals golden: ${R[fail.eq]:-?} (${R[fail.n]:-?} ids); blob by hash: ${R[fail.blob]:-?}"
list_row fail-list fail 1 "the rollback puts the earlier directories back"
sleep 1

# ===========================================================================
# a switch that fails after a complete restore: the restored database is set
# aside, the old one comes back
# ===========================================================================
printf '#!/usr/bin/env bash\n[ "$1" = after-restore ] && exit 1\nexit 0\n' >"$WORK/hook-late.sh"
chmod 700 "$WORK/hook-late.sh"
HAVEN_TEST_SWITCH_HOOK="$WORK/hook-late.sh" haven fail-late --plain db-switch badger --yes
ls -laR "$SB/db" | sed "s#$SB/##" >"$EVID/fail-late.db-ls.txt"
check fail-late-rolled-back "$( [ "${R[fail-late.rc]}" != 0 ] && grep -qx '::result rolled-back' "$EVID/fail-late.log" && echo yes || echo no)" "rc=${R[fail-late.rc]}, $(grep -E '^::result' "$EVID/fail-late.log"); reason: $(grep -o 'The engine switch failed: .*' "$EVID/fail-late.log")"
check fail-late-env-disk "$( [ "$(env_engine)" = lmdb ] && [ "$(only_engine lmdb)" = yes ] && marker_absent && echo yes || echo no)" "DB_ENGINE=$(env_engine); $(disk_report)"
failed_dir=$(newest "-d $SB/db/.failed-*")
check fail-late-restored-set-aside "$( [ -f "$failed_dir/private/MANIFEST" ] && echo yes || echo no)" "set aside with badger files: ${failed_dir#"$SB/"}"
wait_ready fail-late && snap fail-late
check fail-late-serves "$( [ "${R[fail-late.eq]:-no}" = yes ] && [ "${R[fail-late.blob]:-no}" = yes ] && echo yes || echo no)" "sorted ID set equals golden: ${R[fail-late.eq]:-?} (${R[fail-late.n]:-?} ids); blob by hash: ${R[fail-late.blob]:-?}"
list_row fail-late-list fail-late 1 "the rollback puts the earlier directories back"

# ===========================================================================
# the reporter's state (issue #15): DB_ENGINE flipped by hand, relay started
# ===========================================================================
# badger with the golden set first (from the lmdb state the steps above leave)
sleep 1
haven rep-seed --plain db-switch badger --yes
switch_checks rep-seed badger
sleep 1

# the flip by hand, then a start the way the reporter did it: plain compose
# (./haven start now refuses exactly this, see the R3 arm below)
sed -i -E 's/^DB_ENGINE=.*/DB_ENGINE="lmdb"/' "$SB/.env"
dc up -d relay >"$EVID/rep-flip.up.log" 2>&1
wait_ready rep-flip && snap rep-flip
mixed_all() { # yes when all five directories hold files of both engines
  local n b l
  for n in $DIRS; do
    b=$(find "$SB/db/$n" -maxdepth 1 \( -name MANIFEST -o -name KEYREGISTRY -o -name '*.vlog' -o -name '*.sst' \) 2>/dev/null | wc -l)
    l=$(find "$SB/db/$n" -maxdepth 1 \( -name data.mdb -o -name lock.mdb \) 2>/dev/null | wc -l)
    [ "$b" -gt 0 ] && [ "$l" -gt 0 ] || { echo no; return; }
  done
  echo yes
}
check rep-flip-state "$( [ "${R[rep-flip.n]:-x}" = 0 ] && [ "$(mixed_all)" = yes ] && echo yes || echo no)" "after the flip the relay serves ${R[rep-flip.n]:-?} events (want 0); all five directories mixed: $(mixed_all) ($(disk_report))"

# ONE more event while on lmdb — it exists only on the lmdb side
out=$(nakx event -k 1 -c "p3 published while on lmdb after the flip" --ts 1790009999 "ws://127.0.0.1:$PORT" 2>>"$EVID/rep-extra.err")
EXTRA=$(printf '%s\n' "$out" | grep '^{' | jq -r .id)
printf '%s\n' "$EXTRA" >"$EVID/rep-extra.id"
snap rep-extra
check rep-extra-published "$( [ -n "$EXTRA" ] && [ "$(cat "$EVID/rep-extra.ids")" = "$EXTRA" ] && echo yes || echo no)" "the lmdb side serves exactly the extra event ${EXTRA:0:16}… (ids: ${R[rep-extra.n]:-?})"

# (i) ./haven start on the mixed state: goes ahead, one warning line
t5=$(relay_started_at)
haven rep-start --plain start --no-build
wait_ready rep-start && snap rep-start
check rep-start-mixed "$( [ "${R[rep-start.rc]}" = 0 ] && [ "$(grep -c 'db/ holds files of both engines' "$EVID/rep-start.log")" = 1 ] && grep -q -- '--from' "$EVID/rep-start.log" && [ "$(relay_state)" = running ] && [ "$(cat "$EVID/rep-start.ids")" = "$EXTRA" ] && echo yes || echo no)" "rc=${R[rep-start.rc]}; warning: $(grep -o 'db/ holds files of both engines.*' "$EVID/rep-start.log" | head -n1); relay $(relay_state) (StartedAt $t5 -> $(relay_started_at)), still serving only the lmdb side: $(cat "$EVID/rep-start.ids" 2>/dev/null | head -c 16)…"

# (ii) db-switch lmdb --from badger: a clean lmdb database with the golden set
haven rep-switch --plain db-switch lmdb --from badger --yes
switch_checks rep-switch lmdb
mixed_dir=$(newest "-d $SB/db/.pre-switch-mixed-*")
stash_mixed() { local n; for n in $DIRS; do [ -n "$(find "$mixed_dir/$n" -maxdepth 1 -name MANIFEST)" ] && [ -n "$(find "$mixed_dir/$n" -maxdepth 1 -name data.mdb)" ] || { echo no; return; }; done; echo yes; }
check rep-switch-mixed-kept "$( [ -n "$mixed_dir" ] && [ "$(stash_mixed)" = yes ] && echo yes || echo no)" "set aside: ${mixed_dir#"$SB/"}; MANIFEST and data.mdb in all five: $(stash_mixed)"
check rep-switch-backup-side "$(grep -q 'read with DB_ENGINE=badger' "$EVID/rep-switch.log" && echo yes || echo no)" "$(grep -o 'first a verified backup, read with DB_ENGINE=[a-z]*' "$EVID/rep-switch.log")"
# (iii) the extra event is NOT served now ...
check rep-switch-extra-not-served "$( [ -s "$EVID/rep-switch.ids" ] && ! grep -qxF "$EXTRA" "$EVID/rep-switch.ids" && echo yes || echo no)" "extra event in the served ID set: $(grep -cxF "$EXTRA" "$EVID/rep-switch.ids")"
sleep 1

# ... and IS still in the set-aside lmdb files: --rollback puts the mixed layout
# and DB_ENGINE=lmdb back, the relay reads the lmdb side again
haven rep-undo --plain db-switch --rollback --yes
wait_ready rep-undo && snap rep-undo
check rep-undo-mixed-back "$( [ "${R[rep-undo.rc]}" = 0 ] && grep -qx '::result rolled-back' "$EVID/rep-undo.log" && [ "$(env_engine)" = lmdb ] && [ "$(mixed_all)" = yes ] && marker_absent && echo yes || echo no)" "rc=${R[rep-undo.rc]}; DB_ENGINE=$(env_engine); all five mixed: $(mixed_all)"
check rep-undo-extra-served "$( [ "$(cat "$EVID/rep-undo.ids")" = "$EXTRA" ] && echo yes || echo no)" "with DB_ENGINE=lmdb on the restored mixed layout the relay serves: $(tr '\n' ' ' <"$EVID/rep-undo.ids" | head -c 70)"
sleep 1

# (iv) the R3 arm: badger only on disk, DB_ENGINE flipped, relay never started
haven rep-r3-prep --plain db-switch badger --from badger --yes
switch_checks rep-r3-prep badger
haven rep-r3-stop --plain stop
sed -i -E 's/^DB_ENGINE=.*/DB_ENGINE="lmdb"/' "$SB/.env"
haven rep-r3-start --plain start --no-build
check rep-r3-start-refused "$( [ "${R[rep-r3-start.rc]}" != 0 ] && grep -q 'db/ holds badger data, but .env runs the relay on lmdb' "$EVID/rep-r3-start.log" && [ "$(relay_state)" != running ] && [ "$(only_engine badger)" = yes ] && echo yes || echo no)" "rc=${R[rep-r3-start.rc]}; relay $(relay_state); disk still badger only: $(only_engine badger) ($(disk_report))"
haven rep-r3 --plain db-switch lmdb --yes
check rep-r3-found "$(grep -q '.env says DB_ENGINE=lmdb, the data on disk is badger' "$EVID/rep-r3.log" && echo yes || echo no)" "$(grep -o '.env says DB_ENGINE=[a-z]*, the data on disk is [a-z]*' "$EVID/rep-r3.log")"
haven rep-r3-up --plain start --no-build
switch_checks rep-r3 lmdb

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
