#!/usr/bin/env bash
# P4 measurement: the README's plain-compose recipes (backup, restore, engine
# switch by hand), run VERBATIM against the published image in an isolated
# compose project. The command lines are read out of README.md itself — the
# fenced block after each `<!-- recipe:<name> ... -->` marker — so what runs here
# is exactly what the README tells a user to type.
#
# OPT-IN. Not a bats test; needs a running Docker daemon and the image already
# present locally (it never pulls).
#
#   HAVEN_REAL_DOCKER=1 \
#   [P4_EVIDENCE=<empty dir for the evidence files>] \
#   [P4_WORK=<empty work dir outside the repo>] \
#   [P4_IMAGE=holgerhatgarkeinenode/haven-docker:v1.2.2-6] \
#   [P4_N=24] \
#     tests/real-docker/p4-readme-recipe.sh
#
# ISOLATION (same pattern as p2-backup-restore.sh; the script refuses otherwise):
#   - own work dir, refused when it lies inside the repo (or the repo inside it)
#   - sandbox = the repo's docker-compose.yml, sanitised: no container_name, port
#     127.0.0.1::3355 (ephemeral), pull_policy: never
#   - own compose project `havenit-<random>`, given to the README lines through
#     COMPOSE_PROJECT_NAME (read by docker compose itself; the lines stay verbatim)
#   - throwaway owner key (nak), 0600 file in the work dir, evidence scanned for it
#   - cleanup `docker compose -p <project> down -v --remove-orphans` in a trap
#   - the repo's db/, blossom/ and .env are only fingerprinted, before and after
#
# The one README line that is an instruction rather than a command
# ("# now edit .env and set DB_ENGINE=...") is carried out by this script with
# sed on the sandbox .env and logged as such; every other comment line is
# skipped, every command line runs as written, one `bash -c` per line, in the
# sandbox directory.
#
# STEPS (every "serves" row compares the sorted event-ID set with the golden
# set and fetches the blob by hash; counts alone are never a verdict)
#   seed     relay up on badger, N kind-1 notes + one blob, golden ID set
#   backup   recipe:backup — zip verifies (unzip -t), five entries
#   empty    relay stopped, db/<name> moved out of the sandbox, started: serves 0
#   restore  recipe:restore into the emptied database: same ID set, blob
#   switch   recipe:switch (badger -> lmdb by hand): same ID set on lmdb,
#            db/ holds lmdb files, data.mdb apparent vs allocated size

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

IMAGE=${P4_IMAGE:-holgerhatgarkeinenode/haven-docker:v1.2.2-6}
N=${P4_N:-24}
README=$REPO/README.md

# ---------------------------------------------------------------- directories
WORK=${P4_WORK:-}
MADE_TMP=0
if [ -z "$WORK" ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/havenit-p4.XXXXXX") || die "mktemp failed"
  MADE_TMP=1
fi
WORK=$(realpath -m "$WORK")
case "$WORK/" in "$REPO"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "work dir $WORK lies inside the repo $REPO" ;; esac
case "$REPO/" in "$WORK"/*) [ $MADE_TMP = 1 ] && rmdir "$WORK"; die "the repo $REPO lies inside the work dir $WORK" ;; esac
mkdir -p "$WORK" || die "cannot create $WORK"
[ -z "$(ls -A "$WORK")" ] || die "work dir $WORK is not empty"
chmod 700 "$WORK"

EVID=${P4_EVIDENCE:-$WORK/evidence}
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
check() { # name yes/no detail
  R[$1]=$2
  result "$1" "$2 — $3"
  [ "$2" = yes ] || FAIL=1
}

dc() {
  printf '+ docker compose -p %s %s\n' "$PROJ" "$*" >>"$CMDLOG"
  docker compose -p "$PROJ" -f "$SB/docker-compose.yml" --project-directory "$SB" "$@"
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

relay_state() { docker inspect -f '{{.State.Status}}' "$RELAY_NAME" 2>/dev/null || echo none; }

PORT=""
wait_ready() { # label
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

# recipe_lines <name> — the lines of the fenced block after the README marker
recipe_lines() {
  awk -v want="<!-- recipe:$1 " '
    index($0, want) == 1 { armed = 1; next }
    armed && /^```/ { if (inside) exit; inside = 1; next }
    inside { print }
  ' "$README"
}

# run_recipe <name> — every line of the recipe, verbatim, in the sandbox; the
# exit code of each line goes to the evidence (name.lines.tsv)
run_recipe() {
  local name=$1 line n=0 rc out=$EVID/recipe-$1
  recipe_lines "$name" >"$out.txt"
  [ -s "$out.txt" ] || die "README has no recipe:$name block"
  printf 'n\trc\tline\n' >"$out.lines.tsv"
  while IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      "# now edit .env and set DB_ENGINE="*)
        local want=${line#\# now edit .env and set DB_ENGINE=}
        printf '+ [README instruction, done by this script] sed DB_ENGINE=%s into the sandbox .env\n' "$want" >>"$CMDLOG"
        sed -i "s/^DB_ENGINE=.*/DB_ENGINE=$want/" "$SB/.env"; rc=$?
        ;;
      "#"*|"") printf '%s\t-\t%s\n' "$n" "$line" >>"$out.lines.tsv"; continue ;;
      *)
        printf '+ (cd sandbox; COMPOSE_PROJECT_NAME=%s) %s\n' "$PROJ" "$line" >>"$CMDLOG"
        ( cd "$SB" && COMPOSE_PROJECT_NAME=$PROJ bash -c "$line" ) </dev/null >>"$out.log" 2>&1; rc=$?
        ;;
    esac
    printf '%s\t%s\t%s\n' "$n" "$rc" "$line" >>"$out.lines.tsv"
    R[$name.line$n]=$rc
    if [ "$rc" -ne 0 ]; then R[$name.failed]="line $n rc=$rc"; fi
  done <"$out.txt"
  result "recipe-$name" "$(awk -F'\t' 'NR>1 && $2 != "-" {n++; if ($2 == 0) ok++} END {printf "%d of %d command lines exit 0", ok, n}' "$out.lines.tsv")${R[$name.failed]:+ (first failure: ${R[$name.failed]})}"
}

# ===========================================================================
# preflight and sandbox
# ===========================================================================
IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null) \
  || die "image $IMAGE is not present locally (this script never pulls)"
for r in backup restore switch; do
  [ -n "$(recipe_lines "$r")" ] || die "README.md has no recipe:$r block"
done
fingerprint before
docker ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.State}} {{.CreatedAt}}' | sort >"$EVID/docker-ps-before.txt"

{
  echo "date:        $(date -Is)"
  echo "script:      $SELF sha256=$(sha256sum "$0" | cut -c1-16)"
  echo "repo HEAD:   $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
  echo "README:      sha256=$(sha256sum "$README" | cut -c1-16) (working tree copy)"
  echo "image:       $IMAGE"
  echo "image id:    $IMAGE_ID"
  echo "project:     $PROJ   relay container: $RELAY_NAME"
  echo "docker:      $(docker version --format '{{.Server.Version}}' 2>/dev/null) / compose $(docker compose version --short 2>/dev/null)"
  echo "host uid:gid $(id -u):$(id -g)"
  echo "work dir:    $WORK ($(stat -f -c %T "$WORK"))"
  echo "owner npub:  $NPUB   (throwaway key)"
} >"$EVID/environment.txt"

mkdir -p "$SB/db" "$SB/blossom"
cp "$REPO/db/.gitignore" "$SB/db/.gitignore" 2>/dev/null || printf '*\n!.gitignore\n' >"$SB/db/.gitignore"
for f in relays_import relays_blastr whitelisted_npubs blacklisted_npubs; do echo '[]' >"$SB/$f.json"; done
sed -E \
  -e '/^[[:space:]]*container_name:/d' \
  -e 's#"3355:\$\{RELAY_PORT:-3355\}"#"127.0.0.1::3355"#' \
  -e 's#^([[:space:]]*)image:.*$#\1image: '"$IMAGE"'\n\1pull_policy: never#' \
  "$REPO/docker-compose.yml" >"$SB/docker-compose.yml"
grep -q -E 'container_name|haven-relay|"3355:' "$SB/docker-compose.yml" && die "sanitised compose file still carries a fixed name or port"
cp "$SB/docker-compose.yml" "$EVID/compose.sandbox.yml"

: >"$SB/.env"
dc run --rm --no-deps -T --entrypoint cat relay /app/.env.example.upstream >"$WORK/env.upstream" 2>"$EVID/env-extract.err" \
  || die "cannot read .env.example.upstream from the image"
sed -E \
  -e "s#^(OWNER_NPUB|PRIVATE_RELAY_NPUB|CHAT_RELAY_NPUB|OUTBOX_RELAY_NPUB|INBOX_RELAY_NPUB)=.*#\1=\"$NPUB\"#" \
  -e 's#^RELAY_URL=.*#RELAY_URL="localhost"#' \
  -e 's#^BACKUP_PROVIDER=.*#BACKUP_PROVIDER="none"#' \
  -e 's#^DB_ENGINE=.*#DB_ENGINE="badger"#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_TOKENS_PER_INTERVAL)=.*#\1=1000#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_MAX_TOKENS)=.*#\1=1000#' \
  -e 's#^([A-Z]+_RELAY_(EVENT_IP|CONNECTION_RATE)_LIMITER_INTERVAL)=.*#\1=1#' \
  -e 's#^([A-Z]+_RELAY_ALLOW_(EMPTY|COMPLEX)_FILTERS)=.*#\1=true#' \
  "$WORK/env.upstream" >"$SB/.env"
printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" >>"$SB/.env"
grep -q '^BACKUP_PROVIDER="none"' "$SB/.env" || die "backup provider not none"
grep -qx 'DB_ENGINE="badger"' "$SB/.env" || die "sandbox .env does not start on badger"
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
        f.write("%d\tp4 seed %02d %s\n" % (1790000000 + i * 60, i, base64.b64encode(stream(b"p4-note-%d" % i, 450)).decode()))
with open(blob, "wb") as f:
    f.write(stream(b"p4-blob", 8192))
PY
BLOBSHA=$(sha256sum "$WORK/blob.bin" | cut -c1-64)

engine_files() { # what db/ holds, by file names (badger / lmdb / both / none)
  local b l
  b=$(find "$SB/db" -mindepth 2 -maxdepth 2 \( -name MANIFEST -o -name '*.vlog' \) ! -path '*/old-engine/*' 2>/dev/null | wc -l)
  l=$(find "$SB/db" -mindepth 2 -maxdepth 2 -name data.mdb ! -path '*/old-engine/*' 2>/dev/null | wc -l)
  echo "badger_files=$b lmdb_files=$l"
}

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
result seed-engine "$(engine_files)"

# ===========================================================================
# recipe:backup, verbatim
# ===========================================================================
run_recipe backup
Z=$SB/backups/haven-backup.zip
check backup-lines "$( [ -z "${R[backup.failed]:-}" ] && echo yes || echo no)" "every command line of recipe:backup exit 0${R[backup.failed]:+ — ${R[backup.failed]}}"
check backup-unzip-t "$(grep -q 'No errors detected in compressed data of backups/haven-backup.zip' "$EVID/recipe-backup.log" && echo yes || echo no)" "the README's own unzip -t line reports: $(grep -o 'No errors detected.*' "$EVID/recipe-backup.log" | head -1)"
unzip -Z1 "$Z" 2>/dev/null | sort >"$EVID/backup.entries"
check backup-five-entries "$( [ "$(tr '\n' ' ' <"$EVID/backup.entries")" = "blossom.jsonl chat.jsonl inbox.jsonl outbox.jsonl private.jsonl " ] && echo yes || echo no)" "entries: $(tr '\n' ' ' <"$EVID/backup.entries")"
result backup-modes "zip $(stat -c '%a %u:%g' "$Z" 2>/dev/null), backups/ $(stat -c '%a %u:%g' "$SB/backups" 2>/dev/null), host $(id -u):$(id -g)"
check backup-relay-back "$( [ "$(relay_state)" = running ] && echo yes || echo no)" "relay state after the recipe's start line: $(relay_state)"
wait_ready after-backup && snap after-backup
check backup-relay-serves "${R[after-backup.eq]:-no}" "after the recipe the relay serves the golden set"

# ===========================================================================
# empty database (negative control), then recipe:restore, verbatim
# ===========================================================================
dc stop -t 30 relay >"$EVID/empty.stop.log" 2>&1
mkdir -p "$WORK/db-aside"
for d in private chat outbox inbox blossom; do [ -e "$SB/db/$d" ] && mv "$SB/db/$d" "$WORK/db-aside/"; done
dc start relay >>"$EVID/empty.stop.log" 2>&1
wait_ready emptied && snap emptied
check emptied-serves-nothing "$( [ "${R[emptied.n]:-x}" = 0 ] && echo yes || echo no)" "negative control: the emptied db serves ${R[emptied.n]:-?} events"

run_recipe restore
check restore-lines "$( [ -z "${R[restore.failed]:-}" ] && echo yes || echo no)" "every command line of recipe:restore exit 0${R[restore.failed]:+ — ${R[restore.failed]}}"
wait_ready after-restore && snap after-restore
check restore-same-ids "${R[after-restore.eq]:-no}" "sorted ID set after the restore: ${R[after-restore.n]:-?} ids sha256=${R[after-restore.ids]:-?} vs golden ${R[golden.ids]}"
check restore-blob "$( [ "${R[after-restore.blob]:-no}" = yes ] && [ "${R[after-restore.list]:-no}" = yes ] && echo yes || echo no)" "blob fetched by hash: ${R[after-restore.blob]:-?}; blossom list: ${R[after-restore.list]:-?}"

# ===========================================================================
# recipe:switch (badger -> lmdb by hand), verbatim
# ===========================================================================
run_recipe switch
check switch-lines "$( [ -z "${R[switch.failed]:-}" ] && echo yes || echo no)" "every command line of recipe:switch exit 0${R[switch.failed]:+ — ${R[switch.failed]}}"
check switch-unzip-t "$(grep -q 'No errors detected in compressed data of backups/before-switch.zip' "$EVID/recipe-switch.log" && echo yes || echo no)" "the recipe's unzip -t line: $(grep -o 'No errors detected.*' "$EVID/recipe-switch.log" | head -1)"
check switch-env-lmdb "$(grep -qx 'DB_ENGINE="lmdb"' "$SB/.env" && echo yes || echo no)" "sandbox .env: $(grep '^DB_ENGINE=' "$SB/.env")"
ef=$(engine_files)
check switch-db-lmdb "$(case "$ef" in "badger_files=0 lmdb_files="[1-9]*) echo yes ;; *) echo no ;; esac)" "db/ outside old-engine/: $ef; old-engine/: $(find "$SB/db/old-engine" -mindepth 2 -maxdepth 2 -name MANIFEST | wc -l) badger MANIFEST files"
wait_ready after-switch && snap after-switch
check switch-same-ids "${R[after-switch.eq]:-no}" "sorted ID set on lmdb after the switch by hand: ${R[after-switch.n]:-?} ids sha256=${R[after-switch.ids]:-?} vs golden ${R[golden.ids]}"
check switch-blob "$( [ "${R[after-switch.blob]:-no}" = yes ] && [ "${R[after-switch.list]:-no}" = yes ] && echo yes || echo no)" "blob fetched by hash: ${R[after-switch.blob]:-?}; blossom list: ${R[after-switch.list]:-?}"
find "$SB/db" -name data.mdb ! -path '*/old-engine/*' -exec ls -ls {} + 2>/dev/null | sed "s#$SB/##" >"$EVID/data-mdb-ls.txt"
result data-mdb "apparent/allocated per data.mdb on $(stat -f -c %T "$SB/db"): $(find "$SB/db" -name data.mdb ! -path '*/old-engine/*' -printf '%s/%k KiB ' 2>/dev/null)"

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
