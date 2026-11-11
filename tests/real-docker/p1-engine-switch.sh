#!/usr/bin/env bash
# P1 measurement: what really happens to the data when DB_ENGINE changes, and
# whether `backup` / `restore` of the published image can carry it across.
#
# OPT-IN. This is not a bats test and not part of tests/e2e-tui.sh; it needs a
# running Docker daemon and the image already present locally (it never pulls).
#
#   HAVEN_REAL_DOCKER=1 \
#   P1_EVIDENCE=<dir for the evidence files> \
#   [P1_WORK=<empty work dir outside the repo>] \
#   [P1_IMAGE=holgerhatgarkeinenode/haven-docker:v1.2.2-6] \
#   [P1_N=24] \
#     tests/real-docker/p1-engine-switch.sh
#
# ISOLATION (the script refuses to run otherwise):
#   - own work dir, refused when it lies inside the repo (or the repo inside it)
#   - own compose file generated in that work dir, own compose project
#     `havenit-<random>`, no container_name, port 127.0.0.1::3355 (ephemeral),
#     pull_policy: never
#   - throwaway owner key from `nak key generate`; it lives in a 0600 file in the
#     work dir, reaches nak through the environment only, and every evidence file
#     is scanned for it at the end (with a positive control for the scan)
#   - cleanup is `docker compose -p <project> down -v --remove-orphans` in a trap;
#     nothing is ever stopped or removed by container name
#   - the repo's db/, blossom/ and .env are only fingerprinted (hash of .env, never
#     its content), before and after
#
# ARMS (all from pristine copies of one seeded golden badger state):
#   A  flip DB_ENGINE badger -> lmdb only, start               (negative control)
#   B  backup -> flip -> restore -> start                      (naive, mixed dirs)
#   B2 same, but db/<name> moved aside before the restore      (what db-switch will do)
#   C  the reporter's sequence: backup, flip, start, stop, restore, start
#   D  bare `backup` without a path
#   E  lmdb -> badger via backup/restore (source: the end state of B2)
#   F  backup into a too-small tmpfs, swept over page-sized limits
#   G  restore of a truncated zip (populated db, empty db) and of a zip with a
#      damaged entry (empty db)
#   H  restore into a non-empty db, twice
#   T  the verbs under the relay definition of the repo's Tor compose file
#      (config only; the tor service is never started)
#
# Evidence layout: $P1_EVIDENCE/<arm>/..., results.tsv, statements.tsv,
# commands.log, environment.txt, compose.generated.yml.

set -u
set -o pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SELF=$(basename "$0")

die() { echo "$SELF: $*" >&2; exit 1; }

if [ "${HAVEN_REAL_DOCKER:-}" != "1" ]; then
  echo "$SELF: opt-in measurement against a real Docker daemon. Set HAVEN_REAL_DOCKER=1 to run it." >&2
  exit 2
fi

for t in docker nak jq curl unzip python3 sha256sum truncate stat find awk sed timeout; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

IMAGE=${P1_IMAGE:-holgerhatgarkeinenode/haven-docker:v1.2.2-6}
N=${P1_N:-24}

# ---------------------------------------------------------------- directories
WORK=${P1_WORK:-}
MADE_TMP=0
if [ -z "$WORK" ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/havenit-work.XXXXXX") || die "mktemp failed"
  MADE_TMP=1
fi
WORK=$(realpath -m "$WORK")
# Decide before creating anything: the path must not touch the repo in either direction.
case "$WORK/" in "$REPO"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "work dir $WORK lies inside the repo $REPO" ;; esac
case "$REPO/" in "$WORK"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "the repo $REPO lies inside the work dir $WORK" ;; esac
mkdir -p "$WORK" || die "cannot create $WORK"
[ -z "$(ls -A "$WORK")" ] || die "work dir $WORK is not empty"
chmod 700 "$WORK"

EVID=${P1_EVIDENCE:-$WORK/evidence}
mkdir -p "$EVID" || die "cannot create $EVID"
EVID=$(cd "$EVID" && pwd -P)
[ -z "$(ls -A "$EVID")" ] || die "evidence dir $EVID is not empty"

PROJ="havenit-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
CMDLOG=$EVID/commands.log
: >"$CMDLOG"

# ------------------------------------------------------------------- identity
KEY=$(nak key generate 2>/dev/null) || die "nak key generate failed"
case "$KEY" in *[!0-9a-f]*|"") die "unexpected key format" ;; esac
[ ${#KEY} -eq 64 ] || die "unexpected key length"
PKHEX=$(printf '%s' "$KEY" | nak key public 2>/dev/null) || die "cannot derive public key"
NPUB=$(nak encode npub "$PKHEX" 2>/dev/null) || die "cannot encode npub"
( umask 077; printf '%s\n' "$KEY" >"$WORK/owner.key" )

redact() { sed -e "s/$KEY/<owner-key-redacted>/g" -e 's/nsec1[0-9a-z]\{20,\}/<nsec-redacted>/g'; }
nakx() { NOSTR_SECRET_KEY=$KEY timeout 30 nak "$@" </dev/null; }

# ------------------------------------------------------------------- plumbing
ARM="" ARMNAME="" AEV="" PORT="" DC_EXTRA=()
declare -A R
STMT=$EVID/statements.tsv
RES=$EVID/results.tsv
printf 'arm\tstep\tfacts\n' >"$RES"
printf 'id\tstatus\tartefact\tnote\n' >"$STMT"

result() { # step facts...
  local step=$1; shift
  printf '%s\t%s\t%s\n' "${ARMNAME:--}" "$step" "$*" >>"$RES"
  echo "  [${ARMNAME:--}] $step: $*"
}
stmt() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$STMT"; }

dc() {
  printf '+ docker compose -p %s [%s] %s\n' "$PROJ" "$ARMNAME" "$*" | redact >>"$CMDLOG"
  docker compose -p "$PROJ" -f "$ARM/docker-compose.yml" "${DC_EXTRA[@]}" --project-directory "$ARM" "$@"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  echo "cleanup: docker compose -p $PROJ down -v --remove-orphans" >&2
  docker compose -p "$PROJ" -f "$WORK/template/docker-compose.yml" --project-directory "$WORK/template" \
    down -v --remove-orphans >>"$EVID/cleanup.log" 2>&1
  # Leave a readable trace of the leftovers check even when the run died early.
  {
    echo "# leftovers after cleanup (must all be empty)"
    echo "containers:"; docker ps -a --filter "name=havenit-" --format '{{.Names}}'
    echo "networks:";   docker network ls --filter "name=havenit-" --format '{{.Name}}'
    echo "volumes:";    docker volume ls --filter "name=havenit-" --format '{{.Name}}'
  } >"$EVID/leftovers.txt" 2>&1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ----------------------------------------------------------------- fingerprint
# Hash of .env (never its content) and of the data directory listing of the repo.
fingerprint() { # tag
  (
    cd "$REPO" || exit 1
    if [ -f .env ]; then echo "env_sha256=$(sha256sum .env | cut -d' ' -f1)"; else echo "env_sha256=absent"; fi
    echo "data_listing_sha256=$(find db blossom -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
    for f in docker-compose.yml docker-compose.tor.yml entrypoint.sh haven-guard.sh; do
      echo "$f sha256=$(sha256sum "$f" | cut -d' ' -f1)"
    done
  ) >"$EVID/repo-fingerprint-$1.txt"
}

docker_listing() { # tag
  docker ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.State}} {{.CreatedAt}}' | sort >"$EVID/docker-ps-$1.txt"
  { docker network ls --format '{{.Name}}'; docker volume ls --format '{{.Name}}'; } | sort >"$EVID/docker-netvol-$1.txt"
}

# ---------------------------------------------------------------- arm handling
new_arm() { # name source-dir
  ARMNAME=$1
  ARM=$WORK/arms/$1
  AEV=$EVID/$1
  DC_EXTRA=()
  case "$ARM" in "$WORK"/arms/*) ;; *) die "arm path escaped the work dir" ;; esac
  mkdir -p "$WORK/arms" "$AEV"
  cp -a "$2" "$ARM" || die "cannot copy $2 to $ARM"
  rm -rf "$ARM/backups"
  mkdir -p "$ARM/backups"
  echo "== arm $ARMNAME (from $(basename "$2"))"
}

arm_end() {
  tree_snapshot end
  dc down --remove-orphans >>"$AEV/down.log" 2>&1 || result down "rc=$? (see down.log)"
}

set_engine() {
  sed -i -E "s/^DB_ENGINE=.*/DB_ENGINE=\"$1\"/" "$ARM/.env"
  grep -q "^DB_ENGINE=\"$1\"" "$ARM/.env" || die "could not set DB_ENGINE=$1"
  result set-engine "DB_ENGINE=$1"
}

move_aside() { # tag
  local d t=".pre-switch-$1"
  mkdir -p "$ARM/db/$t"
  for d in private chat outbox inbox blossom; do
    [ -d "$ARM/db/$d" ] && mv "$ARM/db/$d" "$ARM/db/$t/$d"
  done
  result move-aside "db/{private,chat,outbox,inbox,blossom} -> db/$t/"
}

tree_snapshot() { # label
  {
    echo "### $ARMNAME :: $1"
    ( cd "$ARM" && ls -lRsA --time-style=+ db )
    echo
  } >>"$AEV/db-ls.txt" 2>&1
}

classify() { # label ; prints the engine markers per db/<name> and returns via R
  local d p b l mixed=0 f=$AEV/$1.engine
  : >"$f"
  for d in private chat outbox inbox blossom; do
    p=$ARM/db/$d; b=0; l=0
    [ -e "$p/MANIFEST" ] && b=1
    compgen -G "$p/*.vlog" >/dev/null && b=1
    [ -e "$p/data.mdb" ] && l=1
    echo "$d badger=$b lmdb=$l" >>"$f"
    [ $b -eq 1 ] && [ $l -eq 1 ] && mixed=$((mixed+1))
  done
  R[$ARMNAME.$1.mixed]=$mixed
  result "classify-$1" "dirs with badger AND lmdb files: $mixed/5"
}

sparse_facts() { # label
  local f=$AEV/$1.sparse.txt m
  : >"$f"
  for m in "$ARM"/db/*/data.mdb; do
    [ -e "$m" ] || continue
    printf '%s apparent=%s allocated=%s blocks512=%s\n' "${m#"$ARM"/}" \
      "$(stat -c %s "$m")" "$(( $(stat -c %b "$m") * $(stat -c %B "$m") ))" "$(stat -c %b "$m")" >>"$f"
    ls -ls "$m" >>"$f"
  done
  {
    echo "du apparent (bytes): $(du -s --apparent-size -B1 "$ARM/db" | cut -f1)"
    echo "du allocated (bytes): $(du -s -B1 "$ARM/db" | cut -f1)"
    echo "fs of work dir: $(stat -f -c %T "$ARM")"
  } >>"$f"
}

owner_facts() { # label
  {
    echo "host uid:gid = $(id -u):$(id -g)"
    echo "# backups/"
    stat -c '%U:%G %u:%g %a %s %n' "$ARM"/backups/* 2>/dev/null | sed "s#$ARM/##"
    echo "# db/ (depth 2)"
    ( cd "$ARM" && find db -maxdepth 2 -printf '%u:%g %U:%G %m %y %p\n' | sort -k5 )
  } >"$AEV/$1.owner.txt"
}

# --------------------------------------------------------------- relay control
start_relay() { # label
  local label=$1 i state ready=0 rc
  PORT=""
  dc up -d relay >"$AEV/$label.up.log" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then result "start-$label" "up rc=$rc (see $label.up.log)"; return 1; fi
  PORT=$(dc port relay 3355 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/')
  for ((i = 0; i < 150; i++)); do
    state=$(dc ps -a --format '{{.State}}' relay 2>/dev/null | head -1)
    [ "$state" = running ] || break
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/"; then ready=1; break; fi
    sleep 0.4
  done
  if [ $ready -ne 1 ]; then
    dc logs --no-color --no-log-prefix relay >"$AEV/$label.relay.log" 2>&1
    result "start-$label" "NOT READY state=${state:-?} exit=$(dc ps -a --format '{{.ExitCode}}' relay 2>/dev/null | head -1)"
    return 1
  fi
  dc exec -T relay sh -c 'cat /proc/net/tcp /proc/net/tcp6' >"$AEV/$label.net.txt" 2>&1
  python3 -I "$WORK/netdec.py" "$AEV/$label.net.txt" >"$AEV/$label.net.summary" 2>&1
  result "start-$label" "ready port=$PORT; $(cat "$AEV/$label.net.summary")"
  return 0
}

stop_relay() { # label
  local label=$1 rc ec left
  dc stop -t 30 relay >"$AEV/$label.stop.log" 2>&1; rc=$?
  ec=$(dc ps -a --format '{{.ExitCode}}' relay 2>/dev/null | head -1)
  dc logs --no-color --no-log-prefix relay >"$AEV/$label.relay.log" 2>&1
  dc rm -f relay >>"$AEV/$label.stop.log" 2>&1
  left=$(dc ps -a -q relay 2>/dev/null | wc -l)
  result "stop-$label" "stop rc=$rc container_exit=${ec:-?} containers_left=$left"
  R[$ARMNAME.$label.stop_exit]=${ec:-?}
}

# ------------------------------------------------------------------- snapshots
# Serve-side evidence: sorted event-ID set via nak req, the blob by hash, the
# blossom list. Expected set defaults to the seeded golden set.
snap() { # label [expected-ids-file]
  local label=$1 expected=${2:-$WORK/ids.expected} f i rc=1 code bsha list n u eq blobok listok
  f=$AEV/$label
  if [ -z "$PORT" ]; then result "snap-$label" "UNAVAILABLE (no running relay)"; R[$ARMNAME.$label.eq]=unavailable; return 1; fi
  for i in 1 2 3; do
    nakx req -k 1 -a "$PKHEX" -l 5000 "ws://127.0.0.1:$PORT" >"$f.raw" 2>"$f.req.err"; rc=$?
    [ $rc -eq 0 ] && break
    sleep 1
  done
  if [ $rc -ne 0 ]; then result "snap-$label" "nak req failed rc=$rc"; R[$ARMNAME.$label.eq]=failed; return 1; fi
  jq -r .id <"$f.raw" 2>/dev/null | sort >"$f.ids.all"
  sort -u "$f.ids.all" >"$f.ids"
  rm -f "$f.raw"
  n=$(wc -l <"$f.ids.all"); u=$(wc -l <"$f.ids")
  if cmp -s "$f.ids" "$expected"; then eq=yes; else eq=no; fi
  code=$(curl -s -m 20 -o "$f.blob" -w '%{http_code}' "http://127.0.0.1:$PORT/$BLOBSHA")
  if [ "$code" = 200 ]; then bsha=$(sha256sum "$f.blob" | cut -c1-64); else bsha=-; fi
  rm -f "$f.blob"
  if [ "$bsha" = "$BLOBSHA" ]; then blobok=yes; else blobok=no; fi
  list=$(curl -s -m 20 "http://127.0.0.1:$PORT/list/$PKHEX" | jq -c -S '[.[].sha256] | sort' 2>/dev/null || echo INVALID)
  [ -n "$list" ] || list=INVALID
  echo "$list" >"$f.bloblist"
  if [ "$list" = "[\"$BLOBSHA\"]" ]; then listok=yes; else listok=no; fi
  R[$ARMNAME.$label.eq]=$eq; R[$ARMNAME.$label.blob]=$blobok; R[$ARMNAME.$label.list]=$listok
  R[$ARMNAME.$label.n]=$n; R[$ARMNAME.$label.uniq]=$u
  result "snap-$label" "ids_sha256=$(sha256sum "$f.ids" | cut -c1-16) lines=$n unique=$u equals_expected=$eq blob_http=$code blob_hash_ok=$blobok blossom_list_ok=$listok"
}

# ------------------------------------------------------------------- verbs
verb() { # label args... ; runs the upstream binary one-shot, returns its exit code
  local label=$1 rc; shift
  mkdir -p "$ARM/backups"
  dc run --rm --no-deps -T -v "$ARM/backups:/app/backups" --entrypoint /app/haven relay "$@" \
    >"$AEV/$label.log" 2>&1
  rc=$?
  result "$label" "verb='$*' rc=$rc"
  R[$ARMNAME.$label.rc]=$rc
  return $rc
}

zip_facts() { # label zipfile
  local label=$1 z=$2 e
  unzip -v "$z" >"$AEV/$label.unzip-v.txt" 2>&1
  unzip -t "$z" >"$AEV/$label.unzip-t.txt" 2>&1; R[$ARMNAME.$label.unzip_t]=$?
  unzip -Z1 "$z" 2>/dev/null | sort >"$AEV/$label.entries"
  unzip -v "$z" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && NF >= 8 {print $8, $7, $1}' | sort >"$AEV/$label.crc"
  : >"$AEV/$label.linehash"
  while IFS= read -r e; do
    printf '%s %s\n' "$e" "$(unzip -p "$z" "$e" 2>/dev/null | sort | sha256sum | cut -c1-16)" >>"$AEV/$label.linehash"
  done <"$AEV/$label.entries"
  unzip -p "$z" blossom.jsonl 2>/dev/null | jq -c '{kind, tag_names: [.tags[][0]], content_bytes: (.content | length)}' >"$AEV/$label.blossom-entry.txt" 2>&1
  stat -c '%U:%G %u:%g %a %s %n' "$z" | sed "s#$ARM/##" >"$AEV/$label.owner.txt"
  result "zip-$label" "unzip_t_rc=${R[$ARMNAME.$label.unzip_t]:-?} entries=$(wc -l <"$AEV/$label.entries") size=$(stat -c %s "$z")"
}

# Comparisons of two evidence files; an empty or short file is "invalid", never
# "same" (two empty files would compare equal and prove nothing).
crc_cmp() { # a b ; both are "<arm>/<label>" evidence prefixes ; prints same|differs|invalid
  if [ "$(wc -l <"$EVID/$1.crc" 2>/dev/null)" != 5 ] || [ "$(wc -l <"$EVID/$2.crc" 2>/dev/null)" != 5 ]; then echo invalid
  elif cmp -s "$EVID/$1.crc" "$EVID/$2.crc"; then echo same; else echo differs; fi
}
lines_cmp() {
  if [ "$(wc -l <"$EVID/$1.linehash" 2>/dev/null)" != 5 ] || [ "$(wc -l <"$EVID/$2.linehash" 2>/dev/null)" != 5 ]; then echo invalid
  elif cmp -s "$EVID/$1.linehash" "$EVID/$2.linehash"; then echo same; else echo differs; fi
}

# ===========================================================================
# preflight
# ===========================================================================
IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null) \
  || die "image $IMAGE is not present locally (this script never pulls)"

fingerprint before
docker_listing before

{
  echo "date:        $(date -Is)"
  echo "script:      $SELF sha256=$(sha256sum "$0" | cut -c1-16)"
  echo "repo HEAD:   $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
  echo "image:       $IMAGE"
  echo "image id:    $IMAGE_ID"
  echo "project:     $PROJ"
  echo "docker:      $(docker version --format '{{.Server.Version}}' 2>/dev/null) / compose $(docker compose version --short 2>/dev/null)"
  echo "nak:         $(nak --version 2>/dev/null | head -1)"
  echo "host uid:gid $(id -u):$(id -g)"
  echo "work dir:    $WORK ($(stat -f -c %T "$WORK"))"
  echo "events N:    $N"
  echo "owner npub:  $NPUB   (throwaway key; the secret never appears in the evidence)"
} >"$EVID/environment.txt"

# --------------------------------------------------------- template (own config)
TPL=$WORK/template
mkdir -p "$TPL/db" "$TPL/blossom"
for f in relays_import relays_blastr whitelisted_npubs blacklisted_npubs; do echo '[]' >"$TPL/$f.json"; done
: >"$TPL/.env"

cat >"$TPL/docker-compose.yml" <<EOF
services:
  relay:
    image: $IMAGE
    pull_policy: never
    env_file:
      - .env
    user: "$(id -u):$(id -g)"
    ports:
      - "127.0.0.1::3355"
    volumes:
      - "./db:/app/db"
      - "./blossom:/app/blossom"
      - "./relays_import.json:/app/relays_import.json"
      - "./relays_blastr.json:/app/relays_blastr.json"
      - "./blacklisted_npubs.json:/app/blacklisted_npubs.json"
      - "./whitelisted_npubs.json:/app/whitelisted_npubs.json"
    restart: "no"
EOF
cp "$TPL/docker-compose.yml" "$EVID/compose.generated.yml"

ARM=$TPL ARMNAME=template AEV=$EVID
docker compose -p "$PROJ" -f "$TPL/docker-compose.yml" --project-directory "$TPL" \
  run --rm --no-deps -T --entrypoint cat relay /app/.env.example.upstream >"$WORK/env.upstream" 2>"$EVID/env-extract.err" \
  || die "cannot read .env.example.upstream from the image (see env-extract.err)"
echo "+ docker compose -p $PROJ [template] run --rm --no-deps -T --entrypoint cat relay /app/.env.example.upstream" >>"$CMDLOG"
[ -s "$WORK/env.upstream" ] || die "empty .env.example.upstream"

# The only deviations from the upstream example: our npub as owner of all four
# relays, a localhost relay URL, no cloud backup, and rate limiters / filter policy
# opened so the seeding client is not answered with 429. Import and blastr lists
# are empty files.
sed -E \
  -e "s#^(OWNER_NPUB|PRIVATE_RELAY_NPUB|CHAT_RELAY_NPUB|OUTBOX_RELAY_NPUB|INBOX_RELAY_NPUB)=.*#\1=\"$NPUB\"#" \
  -e 's#^RELAY_URL=.*#RELAY_URL="localhost"#' \
  -e 's#^BACKUP_PROVIDER=.*#BACKUP_PROVIDER="none"#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_TOKENS_PER_INTERVAL)=.*#\1=1000#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_MAX_TOKENS)=.*#\1=1000#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_INTERVAL)=.*#\1=1#' \
  -e 's#^([A-Z]+_RELAY_ALLOW_(EMPTY|COMPLEX)_FILTERS)=.*#\1=true#' \
  "$WORK/env.upstream" >"$TPL/.env"
diff "$WORK/env.upstream" "$TPL/.env" >"$EVID/env.diff" 2>&1
[ "$(grep -c "^OWNER_NPUB=\"$NPUB\"" "$TPL/.env")" = 1 ] || die "owner npub not set in the generated .env"
grep -q '^BACKUP_PROVIDER="none"' "$TPL/.env" || die "backup provider not none"
grep -q '^LMDB_MAPSIZE=0' "$TPL/.env" || die "LMDB_MAPSIZE is not 0 in the upstream example (statement 7 assumes it)"
grep -q 'nsec' "$TPL/.env" && die "generated .env mentions nsec"

# deterministic seed material: N kind-1 notes (one tie on created_at at 5/6) and one blob
python3 -I - "$N" "$WORK/seed.tsv" "$WORK/blob.bin" <<'PY'
import base64, hashlib, sys
n, out, blob = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def stream(label, size):
    d, x = b"", label
    while len(d) < size:
        x = hashlib.sha256(x).digest()
        d += x
    return d[:size]
BASE = 1790000000
with open(out, "w") as f:
    for i in range(1, n + 1):
        ts = BASE + (5 if i == 6 else i) * 60
        body = base64.b64encode(stream(b"p1-note-%d" % i, 450)).decode()
        f.write("%d\tp1 seed %02d %s\n" % (ts, i, body))
with open(blob, "wb") as f:
    f.write(stream(b"p1-blob", 8192))
PY
BLOBSHA=$(sha256sum "$WORK/blob.bin" | cut -c1-64)

cat >"$WORK/netdec.py" <<'PY'
# Count ESTABLISHED tcp connections whose remote is neither loopback nor a docker
# bridge address: those would be outbound connections of the relay.
import ipaddress, sys
est = out = 0
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) < 4 or p[0] == "sl" or p[3] != "01":
        continue
    est += 1
    h = p[2].split(":")[0]
    b = bytes.fromhex(h)
    if len(b) == 4:
        ip = ipaddress.IPv4Address(b[::-1])
    else:
        words = [b[i:i + 4][::-1] for i in range(0, 16, 4)]
        ip = ipaddress.IPv6Address(b"".join(words))
        if ip.ipv4_mapped:
            ip = ip.ipv4_mapped
    if ip.is_loopback or ip in ipaddress.ip_network("172.16.0.0/12"):
        continue
    out += 1
print("established=%d outbound_established=%d" % (est, out))
PY

# ===========================================================================
# golden: badger relay seeded over the wire
# ===========================================================================
new_arm golden-badger "$TPL"
set_engine badger
start_relay seed || die "golden relay did not start (see $AEV)"
: >"$WORK/ids.expected.raw"
i=0
while IFS=$'\t' read -r ts content; do
  i=$((i + 1))
  ok=0
  for _ in 1 2 3; do
    out=$(nakx event -k 1 -c "$content" --ts "$ts" "ws://127.0.0.1:$PORT" 2>>"$AEV/seed.err") && ok=1 && break
    sleep 1
  done
  [ $ok -eq 1 ] || die "seeding: event $i was not accepted (see $AEV/seed.err)"
  printf '%s\n' "$out" | grep '^{' | jq -r .id >>"$WORK/ids.expected.raw"
done <"$WORK/seed.tsv"
sort -u "$WORK/ids.expected.raw" >"$WORK/ids.expected"
[ "$(wc -l <"$WORK/ids.expected")" = "$N" ] || die "expected $N distinct event ids, got $(wc -l <"$WORK/ids.expected")"
cp "$WORK/ids.expected" "$AEV/ids.expected"
upload=$(nakx blossom upload --server "http://127.0.0.1:$PORT" "$WORK/blob.bin" 2>>"$AEV/seed.err") || die "blob upload failed (see $AEV/seed.err)"
[ "$(printf '%s\n' "$upload" | grep '^{' | jq -r .sha256)" = "$BLOBSHA" ] || die "blob upload did not report the expected sha256"
snap golden-seeded || die "snapshot of the seeded relay failed"
[ "${R[golden-badger.golden-seeded.eq]:-?}" = yes ] || die "the relay does not serve the events that were published"
[ "${R[golden-badger.golden-seeded.blob]:-?}" = yes ] && [ "${R[golden-badger.golden-seeded.list]:-?}" = yes ] || die "the relay does not serve the blob"
stop_relay seed
tree_snapshot golden
classify golden
arm_end
GOLD=$ARM

# ===========================================================================
# A0: a restart of the untouched golden state serves everything (positive control
#     for the comparison used below)
# ===========================================================================
new_arm A0 "$GOLD"
if start_relay restart; then snap restart; stop_relay restart; fi
arm_end

# ===========================================================================
# A: flip only (negative control)
# ===========================================================================
new_arm A "$GOLD"
tree_snapshot before-flip
set_engine lmdb
if start_relay lmdb; then snap lmdb; else R[A.lmdb.eq]=notstarted; fi
classify after-start
tree_snapshot after-start
sparse_facts after-start
[ -n "$PORT" ] && stop_relay lmdb
classify after-stop
tree_snapshot after-stop
# A2: flip back; the badger files were never touched, so the data should return.
set_engine badger
if start_relay back; then snap back; stop_relay back; fi
arm_end
if [ "${R[A.lmdb.eq]:-}" = yes ]; then
  result NEGATIVE-CONTROL "!!! A FLIP ALONE CARRIED THE DATA - THIS OVERTURNS THE PLAN !!!"
fi

# ===========================================================================
# B: backup -> flip -> restore -> start (naive: restore into the mixed dirs)
# ===========================================================================
new_arm B "$GOLD"
verb backup backup /app/backups/b1.zip
zip_facts b1 "$ARM/backups/b1.zip"
owner_facts after-backup
set_engine lmdb
verb restore restore /app/backups/b1.zip
tree_snapshot after-restore
classify after-restore
if start_relay lmdb; then snap lmdb; stop_relay lmdb; fi
arm_end

# ===========================================================================
# B2: the same, with db/<name> moved aside first (the db-switch design)
# ===========================================================================
new_arm B2 "$GOLD"
verb backup1 backup /app/backups/b1.zip
zip_facts b1 "$ARM/backups/b1.zip"
set_engine lmdb
move_aside badger
verb restore restore /app/backups/b1.zip
classify after-restore
if start_relay lmdb; then
  snap lmdb
  sparse_facts after-start
  stop_relay lmdb
fi
tree_snapshot after-stop
sparse_facts after-stop
owner_facts after-stop
verb backup2 backup /app/backups/b2.zip
zip_facts b2 "$ARM/backups/b2.zip"
R[b1_b2_crc]=$(crc_cmp B2/b1 B2/b2)
R[b1_b2_lines]=$(lines_cmp B2/b1 B2/b2)
result crc-round-trip "b1 vs b2 (badger -> lmdb): per-entry CRC ${R[b1_b2_crc]:-?}, sorted-line hashes ${R[b1_b2_lines]:-?}"
arm_end
LMDB_SRC=$ARM

# ===========================================================================
# C: the reporter's sequence
# ===========================================================================
new_arm C "$GOLD"
verb backup backup /app/backups/c1.zip
zip_facts c1 "$ARM/backups/c1.zip"
set_engine lmdb
if start_relay lmdb-first; then snap lmdb-first; stop_relay lmdb-first; fi
classify after-first-start
verb restore restore /app/backups/c1.zip
tree_snapshot after-restore
if start_relay lmdb-final; then snap lmdb-final; stop_relay lmdb-final; fi
arm_end

# ===========================================================================
# D: bare `backup`
# ===========================================================================
new_arm D "$GOLD"
verb bare backup
R[D.bare.leftover]=$(find "$ARM/backups" -type f | wc -l)
result bare-leftover "files in the mounted backups dir: ${R[D.bare.leftover]:-?}"
# D2: the same call, then look around inside the same container (as the image user)
dc run --rm --no-deps -T --entrypoint sh relay -c '/app/haven backup; echo "backup-rc=$?"; echo "--- id"; id; echo "--- ls -ld /app"; ls -ld /app; echo "--- zip files anywhere"; find / -xdev -name "*.zip" 2>/dev/null; echo "--- end"' >"$AEV/bare-user.log" 2>&1
result bare-as-image-user "rc=$? $(grep -E 'backup-rc=' "$AEV/bare-user.log")"
# D3: the same call as root, to see which file name the default would produce
dc run --rm --no-deps -T --user 0 --entrypoint sh relay -c '/app/haven backup; echo "backup-rc=$?"; echo "--- ls -l /app"; ls -l /app; echo "--- zip files anywhere"; find / -xdev -name "*.zip" 2>/dev/null; echo "--- end"' >"$AEV/bare-root.log" 2>&1
result bare-as-root "rc=$? $(grep -E 'backup-rc=' "$AEV/bare-root.log")"
arm_end

# ===========================================================================
# E: lmdb -> badger (source: the end state of B2)
# ===========================================================================
new_arm E "$LMDB_SRC"
verb backup1 backup /app/backups/e1.zip
zip_facts e1 "$ARM/backups/e1.zip"
set_engine badger
move_aside lmdb
verb restore restore /app/backups/e1.zip
classify after-restore
if start_relay badger; then snap badger; stop_relay badger; fi
tree_snapshot after-stop
owner_facts after-stop
verb backup2 backup /app/backups/e2.zip
zip_facts e2 "$ARM/backups/e2.zip"
R[b2_e1_crc]=$(crc_cmp B2/b2 E/e1)
R[e1_e2_crc]=$(crc_cmp E/e1 E/e2)
R[b1_e2_crc]=$(crc_cmp B2/b1 E/e2)
R[e1_e2_lines]=$(lines_cmp E/e1 E/e2)
result crc-round-trip "b2 vs e1 (same lmdb db): ${R[b2_e1_crc]:-?}; e1 vs e2 (lmdb -> badger): CRC ${R[e1_e2_crc]:-?}, sorted lines ${R[e1_e2_lines]:-?}; b1 vs e2 (full circle): ${R[b1_e2_crc]:-?}"
arm_end

# ===========================================================================
# F: backup into a too-small tmpfs, swept over page-sized limits
# ===========================================================================
new_arm F "$GOLD"
verb good backup /app/backups/good.zip
zip_facts good "$ARM/backups/good.zip"
S=$(stat -c %s "$ARM/backups/good.zip")
CEIL=$(( (S + 4095) / 4096 * 4096 ))
START=$(( CEIL - 8 * 4096 )); [ $START -lt 4096 ] && START=4096
SIZES=""
for ((s = START; s < CEIL; s += 4096)); do SIZES="$SIZES $s"; done
SIZES="$SIZES $CEIL"
[ 65536 -gt "$CEIL" ] && SIZES="$SIZES 65536"
R[F.rc0_bad]=0
: >"$AEV/sweep.tsv"
printf 'tmpfs_bytes\tbackup_rc\touter_rc\tzip_bytes\tunzip_t_rc\tlog_error_line\n' >>"$AEV/sweep.tsv"
result sweep "good zip is $S bytes; sweeping tmpfs sizes:$SIZES"
for sz in $SIZES; do
  od=$ARM/out-$sz; mkdir -p "$od"
  printf 'services:\n  relay:\n    tmpfs:\n      - /app/backups:size=%s,mode=1777\n' "$sz" >"$ARM/tmpfs-$sz.yml"
  DC_EXTRA=(-f "$ARM/tmpfs-$sz.yml")
  dc run --rm --no-deps -T -v "$od:/out" --entrypoint sh relay -c \
    '/app/haven backup /app/backups/f.zip >/out/log.txt 2>&1; rc=$?; echo $rc >/out/inner-rc; ls -l /app/backups >/out/ls.txt 2>&1; cp /app/backups/f.zip /out/f.zip 2>/out/cp.err; exit $rc' \
    >"$AEV/sweep-$sz.outer.log" 2>&1
  outer=$?
  DC_EXTRA=()
  inner=$(cat "$od/inner-rc" 2>/dev/null || echo "?")
  cp "$od/log.txt" "$AEV/sweep-$sz.log" 2>/dev/null
  zb=-; ut=-
  if [ -f "$od/f.zip" ]; then
    zb=$(stat -c %s "$od/f.zip")
    unzip -t "$od/f.zip" >"$AEV/sweep-$sz.unzip-t.txt" 2>&1; ut=$?
  fi
  err=$(grep -E 'ERROR|error' "$od/log.txt" 2>/dev/null | tail -1 | sed -E 's/^[0-9/]+ [0-9:]+ //' | cut -c1-150)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sz" "$inner" "$outer" "$zb" "$ut" "$err" >>"$AEV/sweep.tsv"
  if [ "$inner" = 0 ] && { [ "$ut" = - ] || [ "$ut" != 0 ]; }; then R[F.rc0_bad]=$(( ${R[F.rc0_bad]:-?} + 1 )); fi
done
[ -n "${R[F.rc0_bad]:-?}" ] && result sweep-summary "exit 0 with a missing or invalid zip in ${R[F.rc0_bad]:-?} of $(echo "$SIZES" | wc -w) runs (see sweep.tsv)"
arm_end

# ===========================================================================
# G: restore of damaged zips
# ===========================================================================
new_arm G "$GOLD"
verb good backup /app/backups/good.zip
GS=$(stat -c %s "$ARM/backups/good.zip")
cp "$ARM/backups/good.zip" "$ARM/backups/trunc.zip"
truncate -s $(( GS * 2 / 3 )) "$ARM/backups/trunc.zip"
unzip -t "$ARM/backups/trunc.zip" >"$AEV/trunc.unzip-t.txt" 2>&1; ut=$?
result truncated-zip "from $GS to $(stat -c %s "$ARM/backups/trunc.zip") bytes; unzip -t rc=$ut"
# Opening a badger db rotates its value log (000001.vlog -> 000002.vlog ...), so a
# changed file listing alone proves nothing. Control: a successful, read-only
# backup is run first and its effect on the listing is recorded next to the
# effect of the failed restore.
listing() { ( cd "$ARM" && find db -type f -printf '%P %s\n' | sort ); }
listing >"$AEV/db-files-0-before-control.txt"
verb control-backup backup /app/backups/control.zip
listing >"$AEV/db-files-1-after-control-backup.txt"
verb restore-trunc restore /app/backups/trunc.zip
listing >"$AEV/db-files-2-after-failed-restore.txt"
if cmp -s "$AEV/db-files-0-before-control.txt" "$AEV/db-files-1-after-control-backup.txt"; then R[G.control_changes]=no; else R[G.control_changes]=yes; fi
if cmp -s "$AEV/db-files-1-after-control-backup.txt" "$AEV/db-files-2-after-failed-restore.txt"; then R[G.restore_changes]=no; else R[G.restore_changes]=yes; fi
result g1-db-files "populated db, file names+sizes: changed by a successful read-only backup (control): ${R[G.control_changes]:-?}; changed by the failed restore: ${R[G.restore_changes]:-?}"
if start_relay after-trunc; then snap after-trunc; stop_relay after-trunc; fi
cp "$ARM/backups/trunc.zip" "$WORK/trunc.zip"
cp "$ARM/backups/good.zip" "$WORK/good-g.zip"
arm_end

new_arm G2 "$TPL"
cp "$WORK/trunc.zip" "$ARM/backups/trunc.zip"
verb restore-trunc restore /app/backups/trunc.zip
tree_snapshot after-restore
classify after-restore
if start_relay empty-trunc; then snap empty-trunc; stop_relay empty-trunc; fi
arm_end

new_arm G3 "$TPL"
python3 -I - "$WORK/good-g.zip" "$ARM/backups/damaged.zip" <<'PY'
import shutil, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
shutil.copy(src, dst)
z = zipfile.ZipFile(src)
zi = z.getinfo("outbox.jsonl")
start = zi.header_offset + 30 + len(zi.filename.encode()) + len(zi.extra)
pos = start + zi.compress_size // 2
with open(dst, "r+b") as f:
    f.seek(pos)
    b = f.read(1)
    f.seek(pos)
    f.write(bytes([b[0] ^ 0xFF]))
print("flipped one byte at offset %d inside outbox.jsonl (compressed %d bytes)" % (pos, zi.compress_size))
PY
unzip -t "$ARM/backups/damaged.zip" >"$AEV/damaged.unzip-t.txt" 2>&1; ut=$?
result damaged-zip "one byte flipped inside outbox.jsonl; unzip -t rc=$ut"
verb restore-damaged restore /app/backups/damaged.zip
tree_snapshot after-restore
if start_relay empty-damaged; then snap empty-damaged; stop_relay empty-damaged; fi
arm_end

# ===========================================================================
# H: restore into a non-empty db, twice
# ===========================================================================
new_arm H "$GOLD"
verb backup backup /app/backups/h0.zip
if start_relay with-extra; then
  extra=$(nakx event -k 1 -c "p1 extra note, not in the backup" --ts 1790009999 "ws://127.0.0.1:$PORT" 2>>"$AEV/extra.err" | grep '^{' | jq -r .id)
  [ -n "$extra" ] || die "could not publish the extra event"
  { cat "$WORK/ids.expected"; echo "$extra"; } | sort -u >"$AEV/ids.with-extra"
  snap with-extra "$AEV/ids.with-extra"
  stop_relay with-extra
fi
verb backup-extra backup /app/backups/h1.zip
zip_facts h1 "$ARM/backups/h1.zip"
zip_facts h0 "$ARM/backups/h0.zip"
R[H.negctl]=$(crc_cmp H/h0 H/h1)
result crc-negative-control "backup before vs after one extra event: per-entry CRC ${R[H.negctl]:-?} (must be 'differs', else the CRC comparison cannot fail)"
for pass in 1 2; do
  verb "restore-$pass" restore /app/backups/h0.zip
  grep -i -E 'dup|skip|exist|import|restor|count' "$AEV/restore-$pass.log" | cut -c1-200 >"$AEV/restore-$pass.summary" 2>/dev/null
  if start_relay "after-restore-$pass"; then snap "after-restore-$pass" "$AEV/ids.with-extra"; stop_relay "after-restore-$pass"; fi
done
verb backup-merged backup /app/backups/h2.zip
zip_facts h2 "$ARM/backups/h2.zip"
R[H.h1_h2_crc]=$(crc_cmp H/h1 H/h2)
for pass in 1 2; do
  R[H.imported$pass]=$(grep -o 'imported events count=[0-9]*' "$AEV/restore-$pass.log" | sed 's/.*=//' | awk '{s+=$1} END {print s+0}')
done
result merge-counts "events the restore reports as imported: pass 1 = ${R[H.imported1]:-?}, pass 2 = ${R[H.imported2]:-?} (the zip holds $N events plus the blossom index); backup after the merge vs backup with the extra event: per-entry CRC ${R[H.h1_h2_crc]:-?}"
if cmp -s "$AEV/with-extra.ids" "$AEV/after-restore-1.ids" && cmp -s "$AEV/after-restore-1.ids" "$AEV/after-restore-2.ids"; then
  R[H.same]=yes
else
  R[H.same]=no
fi
result merge-summary "ID set with extra event == after restore 1 == after restore 2: ${R[H.same]:-?}; extra event kept: $(grep -c "^$extra\$" "$AEV/after-restore-2.ids")"
arm_end

# ===========================================================================
# T: the verbs under the relay definition of the repo's Tor compose file
# ===========================================================================
sanitize_compose() { # src dst : drop container_name, ephemeral loopback port, never pull
  sed -E \
    -e '/^[[:space:]]*container_name:/d' \
    -e 's#"3355:\$\{RELAY_PORT:-3355\}"#"127.0.0.1::3355"#' \
    -e 's#^([[:space:]]*)image:.*$#&\n\1pull_policy: never#' \
    "$1" >"$2"
  if grep -q -E 'container_name|haven-relay|haven-tor|"3355:' "$2"; then die "sanitized $2 still carries a fixed name or port"; fi
}
for variant in base tor; do
  new_arm "T-$variant" "$GOLD"
  src=$REPO/docker-compose.yml; [ "$variant" = tor ] && src=$REPO/docker-compose.tor.yml
  sanitize_compose "$src" "$ARM/docker-compose.yml"
  diff "$src" "$ARM/docker-compose.yml" >"$AEV/sanitize.diff" 2>&1
  cp "$ARM/docker-compose.yml" "$AEV/compose.sanitized.yml"
  verb backup backup /app/backups/t.zip
  zip_facts t "$ARM/backups/t.zip"
  dc config --format json 2>"$AEV/config.err" | jq -S '.services.relay | del(.environment) | .volumes |= map(.target)' >"$AEV/relay-service.json"
  result relay-service-config "services=$(dc config --services 2>/dev/null | tr '\n' ' ') relay_json_bytes=$(wc -c <"$AEV/relay-service.json")"
  R[T.$variant.tor_containers]=$(dc ps -a -q tor 2>/dev/null | wc -l)
  arm_end
done
if cmp -s "$EVID/T-base/relay-service.json" "$EVID/T-tor/relay-service.json" && [ -s "$EVID/T-base/relay-service.json" ]; then R[T.config]=identical; else R[T.config]=differs; fi
R[T.crc]=$(crc_cmp T-base/t T-tor/t)
R[T.vs_b1]=$(crc_cmp T-base/t B2/b1)
ARMNAME=T
result tor-equivalence "relay service config (environment dropped, mounts by target): ${R[T.config]:-?}; backup via base vs tor file per-entry CRC: ${R[T.crc]:-?}; vs b1: ${R[T.vs_b1]:-?}; tor containers created: base=${R[T.base.tor_containers]:-?} tor=${R[T.tor.tor_containers]:-?}"

# ===========================================================================
# statements
# ===========================================================================
ARMNAME=statements

# 1: flip without restore puts lmdb files next to badger files
m=${R[A.after-start.mixed]:-?}
if [ "$m" != "?" ] && [ "$m" -ge 1 ]; then
  stmt 1 confirmed "A/after-start.engine A/after-start.sparse.txt A/db-ls.txt" "$m of 5 db/<name> directories hold badger and lmdb files side by side after a start with DB_ENGINE=lmdb; relay served equals_expected=${R[A.lmdb.eq]:-?}; after flipping back the data is ${R[A.back.eq]:-?}"
else
  stmt 1 refuted "A/after-start.engine" "no directory holds both engines' files (mixed=$m)"
fi

# 2: bare backup cannot write to /app
if [ "${R[D.bare.rc]:-0}" != 0 ] && grep -q -i -E 'permission denied|read-only|denied|cannot|no such' "$EVID/D/bare.log"; then
  stmt 2 confirmed "D/bare.log D/bare-user.log D/bare-root.log" "rc=${R[D.bare.rc]:-?}; $(grep -i -E 'denied|cannot|read-only|error' "$EVID/D/bare.log" | tail -1 | sed -E 's/^[0-9/]+ [0-9:]+ //' | cut -c1-160)"
else
  stmt 2 refuted "D/bare.log" "rc=${R[D.bare.rc]:-?}; no write-failure message found"
fi

# 3: exit code of backup is not a reliable success signal
if [ "${R[F.rc0_bad]:-0}" -ge 1 ]; then
  stmt 3 confirmed "F/sweep.tsv" "exit 0 with a missing or invalid zip in ${R[F.rc0_bad]:-?} sweep runs; see the log_error_line column"
else
  stmt 3 refuted "F/sweep.tsv" "in this sweep every failing run exited non-zero"
fi

# 4: identical per-entry CRC across engines after a round trip
if [ "${R[H.negctl]:-?}" != differs ]; then
  stmt 4 open "H/h0.crc H/h1.crc" "the CRC comparison failed its negative control (${R[H.negctl]:-?}); no CRC statement can be made"
elif [ "${R[b1_b2_crc]:-?}" = same ] && [ "${R[b2_e1_crc]:-?}" = same ] && [ "${R[e1_e2_crc]:-?}" = same ] && [ "${R[b1_e2_crc]:-?}" = same ]; then
  stmt 4 confirmed "B2/b1.crc B2/b2.crc E/e1.crc E/e2.crc" "badger -> lmdb -> badger: all four per-entry CRC lists identical"
else
  stmt 4 refuted "B2/b1.crc B2/b2.crc E/e1.crc E/e2.crc" "b1/b2 CRC ${R[b1_b2_crc]:-?} (sorted lines ${R[b1_b2_lines]:-?}); b2/e1 ${R[b2_e1_crc]:-?}; e1/e2 ${R[e1_e2_crc]:-?} (sorted lines ${R[e1_e2_lines]:-?}); b1/e2 ${R[b1_e2_crc]:-?}"
fi

# 5: five .jsonl entries incl. the blossom index, no media files
want="blossom.jsonl chat.jsonl inbox.jsonl outbox.jsonl private.jsonl"
have=$(tr '\n' ' ' <"$EVID/B2/b1.entries" | sed 's/ $//')
bl=$(unzip -p "$WORK/arms/B2/backups/b1.zip" blossom.jsonl 2>/dev/null | wc -l)
if [ "$have" = "$want" ] && ! grep -q "$BLOBSHA" "$EVID/B2/b1.entries" && [ "$bl" -ge 1 ]; then
  stmt 5 confirmed "B2/b1.unzip-v.txt B2/b1.entries" "entries: $have; blossom.jsonl holds $bl line(s); the blob's sha256 is not an entry name (blob lives in blossom/, not in the zip)"
else
  stmt 5 refuted "B2/b1.unzip-v.txt B2/b1.entries" "entries: $have; blossom.jsonl lines: $bl"
fi

# 6: restore merges and skips duplicates
if [ "${R[H.same]:-?}" = yes ] && [ "${R[H.after-restore-1.n]:-?}" = "${R[H.after-restore-1.uniq]:-?}" ] && [ "${R[H.after-restore-2.n]:-?}" = "${R[H.after-restore-2.uniq]:-?}" ]; then
  stmt 6 confirmed "H/with-extra.ids H/after-restore-1.ids H/after-restore-2.ids H/restore-1.log H/restore-2.log" "extra event survived two restores of an older zip, ID sets identical, no duplicate lines (n=${R[H.after-restore-2.n]:-?}); restore reports imported events: pass1=${R[H.imported1]:-?} pass2=${R[H.imported2]:-?}; backup after the merge vs before: CRC ${R[H.h1_h2_crc]:-?}"
else
  stmt 6 refuted "H/after-restore-1.ids H/after-restore-2.ids" "same=${R[H.same]:-?} lines/unique after 1: ${R[H.after-restore-1.n]:-?}/${R[H.after-restore-1.uniq]:-?}, after 2: ${R[H.after-restore-2.n]:-?}/${R[H.after-restore-2.uniq]:-?}"
fi

# 7: lmdb data.mdb is sparse with a large apparent size at LMDB_MAPSIZE=0
sp=$EVID/B2/after-stop.sparse.txt
ap=$(awk '/apparent=/ {split($2,a,"="); print a[2]}' "$sp" | sort -n | tail -1)
al=$(awk '/allocated=/ {split($3,a,"="); print a[2]}' "$sp" | sort -n | tail -1)
if [ -n "$ap" ] && [ "$ap" -ge $((10 * 1024 * 1024 * 1024)) ] && [ "$al" -lt $((ap / 100)) ]; then
  stmt 7 confirmed "B2/after-stop.sparse.txt" "largest data.mdb: apparent $ap bytes, allocated $al bytes (fs: $(stat -f -c %T "$WORK"))"
else
  stmt 7 refuted "B2/after-stop.sparse.txt" "largest data.mdb: apparent ${ap:-none} bytes, allocated ${al:-none}"
fi

# 8: --entrypoint /app/haven with run -v works without change to entrypoint.sh or the compose files
ok8=yes
for k in B2.backup1 B2.restore B2.backup2 E.backup1 E.restore E.backup2 T-base.backup T-tor.backup; do
  [ "${R[$k.rc]:-x}" = 0 ] || ok8="no ($k rc=${R[$k.rc]:-?})"
done
if [ "$ok8" = yes ] && [ "${R[T.config]:-?}" = identical ] && [ "${R[T.crc]:-?}" = same ]; then
  stmt 8 confirmed "B2/*.log T-base/backup.log T-tor/backup.log T-tor/relay-service.json repo-fingerprint-after.txt" "all one-shot verbs exited 0 through the published image; relay service config of docker-compose.yml and docker-compose.tor.yml identical; backups via both files carry identical per-entry CRC; entrypoint.sh and compose files in the repo unchanged (fingerprint)"
else
  stmt 8 refuted "B2/*.log T-base T-tor" "verbs: $ok8; config ${R[T.config]:-?}; CRC ${R[T.crc]:-?}"
fi

# 9: reporter's sequence ends with all data present
if [ "${R[C.lmdb-final.eq]:-?}" = yes ] && [ "${R[C.lmdb-final.blob]:-?}" = yes ] && [ "${R[C.lmdb-final.list]:-?}" = yes ]; then
  stmt 9 confirmed "C/lmdb-first.ids C/lmdb-final.ids C/restore.log" "after the first start the lmdb relay served equals_expected=${R[C.lmdb-first.eq]:-?}; after the restore equals_expected=yes, blob hash ok, blossom list ok"
else
  stmt 9 refuted "C/lmdb-final.ids C/restore.log" "final: ids=${R[C.lmdb-final.eq]:-?} blob=${R[C.lmdb-final.blob]:-?} list=${R[C.lmdb-final.list]:-?}"
fi

# ===========================================================================
# closing checks: repo untouched, nothing left behind, no key in the evidence
# ===========================================================================
ARMNAME=final
fingerprint after
if cmp -s "$EVID/repo-fingerprint-before.txt" "$EVID/repo-fingerprint-after.txt"; then
  result repo-fingerprint "unchanged"
else
  result repo-fingerprint "!!! CHANGED !!!"; diff "$EVID/repo-fingerprint-before.txt" "$EVID/repo-fingerprint-after.txt" >>"$EVID/repo-fingerprint.diff"
fi

docker compose -p "$PROJ" -f "$TPL/docker-compose.yml" --project-directory "$TPL" down -v --remove-orphans >>"$EVID/cleanup.log" 2>&1
docker_listing after
if diff <(grep ' haven-' "$EVID/docker-ps-before.txt" | grep -v ' havenit-') <(grep ' haven-' "$EVID/docker-ps-after.txt" | grep -v ' havenit-') >"$EVID/docker-ps.diff"; then
  result docker-ps "containers named haven-* unchanged (ID, name, state, creation time)"
else
  result docker-ps "!!! containers named haven-* CHANGED (docker-ps.diff) !!!"
fi
left=$(grep -c havenit- "$EVID/docker-ps-after.txt" "$EVID/docker-netvol-after.txt" | awk -F: '{s+=$2} END {print s}')
result leftovers "havenit-* containers, networks and volumes after down: $left"

scan_key() { grep -rIl -e "$KEY" -e 'nsec1[0-9a-z]\{20,\}' "$1" 2>/dev/null | wc -l; }
printf 'canary %s\n' "$KEY" >"$WORK/canary.txt"
canary_hits=$(scan_key "$WORK/canary.txt")
# redact in place, then scan; the canary must be found by the same scan
for f in $(grep -rIl -e "$KEY" "$EVID" 2>/dev/null); do sed -i "s/$KEY/<owner-key-redacted>/g" "$f"; done
real_hits=$(scan_key "$EVID")
result key-scan "files in the evidence containing the owner key or an nsec: $real_hits (positive control: scan finds the planted canary: $canary_hits)"

result elapsed "whole run ${SECONDS}s"
echo
echo "=== results.tsv"; cat "$RES"
echo "=== statements.tsv"; cat "$STMT"
echo "evidence: $EVID"
[ "$real_hits" = 0 ] && [ "$canary_hits" = 1 ] || exit 1
exit 0
