#!/usr/bin/env bash
#
# woven-migration-rehearsal.sh — pre-deploy migration rehearsal + upgrade-safety gate.
#
# Restores a prod copy into an ISOLATED scratch stack and proves, WITHOUT ever
# touching the live deployment:
#   (a) predeploy (prisma migrate deploy + data migrations) exits 0 on the NEW image;
#   (b) a SECOND predeploy run is a no-op  (idempotency, proven by DB-state diff);
#   (c) the PREVIOUS (currently-deployed) image boots and READS + WRITES the new schema;
#   (d) no destructive/contracting migration slips through (4 independent detectors).
#
# Live target is resolved BY IDENTITY (container publishing :3010) via
# woven-resolve-live.sh — robust to compose-project renames. On success it writes a
# rehearsal token bound to the candidate image id (consumed by woven-promote.sh).
# See .beads/woven-cd-gate.md §9 (bead affine-4yo.4).
#
# Usage:   scripts/woven-migration-rehearsal.sh [NEW_IMAGE]
# Env:
#   WOVEN_REHEARSAL_IMAGE  NEW image to test (default: woven/affine:<sha> if built, else live image ref)
#   WOVEN_PREV_IMAGE       PREVIOUS image for backward-compat (default: live image id)
#   WOVEN_MAKE_BACKUP=1    take a fresh backup if none exists
#   WOVEN_REHEARSAL_PORT   host port for the booted PREV server (default: 3021)
#   WOVEN_ALLOW_ROWLOSS=1  permit a core-table row DECREASE (intentional cleanup migration)
#   WOVEN_KEEP=1           keep the scratch stack up for inspection (no teardown)
#
set -euo pipefail

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[woven-rehearsal]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[woven-rehearsal] ✔${c_rst} $*"; }
warn() { printf '%s\n' "${c_ylw}[woven-rehearsal] ⚠${c_rst} $*" >&2; }
die()  { printf '%s\n' "${c_red}[woven-rehearsal] ✗${c_rst} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
COMPOSE_FILE="$SCRIPT_DIR/woven-restore.compose.yml"
[ -f "$COMPOSE_FILE" ] || die "missing scratch compose: $COMPOSE_FILE"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/woven-resolve-live.sh"
command -v docker >/dev/null 2>&1 || die "docker not found"

# ---- config ---------------------------------------------------------------
PROJECT="${WOVEN_REHEARSAL_PROJECT:-affine_rehearsal}"
export RESTORE_PORT="${WOVEN_REHEARSAL_PORT:-3021}"     # MUST_FIX .4-4: 3021 (staging owns 3020)
SCRATCH_ROOT="${WOVEN_REHEARSAL_DIR:-$HOME/.affine/rehearsal-drill}"
BACKUP_ROOT="${WOVEN_BACKUP_DIR:-$HOME/.affine/backups}"
export DB_USERNAME=affine DB_PASSWORD=affine DB_DATABASE=affine   # throwaway; dump is --no-owner
PRISMA_DIR="$REPO_ROOT/packages/backend/server/migrations"
DATA_DIR="$REPO_ROOT/packages/backend/server/src/data/migrations"

woven_resolve_live      # -> LIVE_SERVER/LIVE_PROJECT/LIVE_PG/LIVE_IMAGE_ID/LIVE_IMAGE_REF

# ---- live-safety guard (never collide with a real/sibling stack) ----------
[ -n "$PROJECT" ] || die "empty PROJECT"
case " $LIVE_PROJECT woven-local affine affine_dev_services affine_restore_drill affine_staging " in
  *" $PROJECT "*) die "refuse: PROJECT '$PROJECT' collides with a real/sibling stack";;
esac
case "$SCRATCH_ROOT" in *"/.affine/self-host"*|"") die "bad SCRATCH_ROOT";; esac
lsof -nP -iTCP:"$RESTORE_PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "port $RESTORE_PORT busy"
docker ps --filter publish="$RESTORE_PORT" --format '{{.Names}}' | grep -q . && die "port $RESTORE_PORT owned by a container"

# ---- image resolution (MUST_FIX .4-2: NO silent :stable; die if unresolved) ----
SHORT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
NEW_IMAGE="${WOVEN_REHEARSAL_IMAGE:-${1:-}}"
if [ -z "$NEW_IMAGE" ]; then
  if docker image inspect "woven/affine:$SHORT_SHA" >/dev/null 2>&1; then NEW_IMAGE="woven/affine:$SHORT_SHA"
  else NEW_IMAGE="$LIVE_IMAGE_REF"; fi        # concrete digest-pinned ref, never a bare :stable guess
fi
PREV_IMAGE="${WOVEN_PREV_IMAGE:-$LIVE_IMAGE_ID}"      # exact running binary (immutable id)
docker image inspect "$NEW_IMAGE"  >/dev/null 2>&1 || die "NEW image '$NEW_IMAGE' not present locally"
docker image inspect "$PREV_IMAGE" >/dev/null 2>&1 || die "PREV image '$PREV_IMAGE' not present (pruned?) — keep it (docker save / a woven tag) to run the backward-compat test"
log "NEW=$NEW_IMAGE"
log "PREV=$PREV_IMAGE"
log "live=$LIVE_SERVER  project=$LIVE_PROJECT  pg=$LIVE_PG"

# ---- resolve backup (patched woven-backup.sh, correct live identity) -------
BACKUP_DIR="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"
if [ -z "$BACKUP_DIR" ] && [ "${WOVEN_MAKE_BACKUP:-0}" = 1 ]; then
  WOVEN_PG_CONTAINER="$LIVE_PG" WOVEN_SERVER_CONTAINER="$LIVE_SERVER" \
    WOVEN_DB_USER=affine WOVEN_DB_NAME=affine "$SCRIPT_DIR/woven-backup.sh"
  BACKUP_DIR="$(ls -1d "$BACKUP_ROOT"/*/ | sort | tail -1)"
fi
[ -n "$BACKUP_DIR" ] || die "no backup found; run scripts/woven-backup.sh or set WOVEN_MAKE_BACKUP=1"
BACKUP_DIR="${BACKUP_DIR%/}"
for f in affine-db.sql.gz storage.tar.gz config.tar.gz; do [ -f "$BACKUP_DIR/$f" ] || die "backup missing $f"; done
log "restoring from: $BACKUP_DIR"

# ---- scratch + restore (same mechanics as woven-restore.sh) ---------------
TS="$(date +%Y%m%d-%H%M%S)"; SCRATCH="$SCRATCH_ROOT/$TS"
export DB_DATA_LOCATION="$SCRATCH/pgdata" UPLOAD_LOCATION="$SCRATCH/storage" CONFIG_LOCATION="$SCRATCH/config"
mkdir -p "$DB_DATA_LOCATION" "$SCRATCH/_x"
extract_to(){ local top; top="$(tar -tzf "$1"|head -1|cut -d/ -f1)"; [ -n "$top" ]||die "empty archive $1"; tar -xzf "$1" -C "$SCRATCH/_x"; rm -rf "$2"; mv "$SCRATCH/_x/$top" "$2"; }
extract_to "$BACKUP_DIR/storage.tar.gz" "$UPLOAD_LOCATION"
extract_to "$BACKUP_DIR/config.tar.gz"  "$CONFIG_LOCATION"; rm -rf "$SCRATCH/_x"
[ -f "$CONFIG_LOCATION/private.key" ] || die "restored config missing private.key"

dc(){ docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }
cleanup(){ local code=$?; if [ "${WOVEN_KEEP:-0}" = 1 ]; then
    warn "WOVEN_KEEP=1 — kept. Teardown: docker compose -p $PROJECT -f $COMPOSE_FILE down -v && rm -rf '$SCRATCH'"
  else dc down -v >/dev/null 2>&1 || true; rm -rf "$SCRATCH" 2>/dev/null || true; fi; exit $code; }
trap cleanup EXIT

export AFFINE_IMAGE="$NEW_IMAGE"
log "starting scratch postgres + redis (indexer OFF)…"
dc up -d postgres redis
PGID="$(dc ps -q postgres)"; [ -n "$PGID" ] || die "scratch pg did not start"
for i in $(seq 1 40); do [ "$(docker inspect "$PGID" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break; sleep 2; done
[ "$(docker inspect "$PGID" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] || die "scratch pg unhealthy"
gzip -dc "$BACKUP_DIR/affine-db.sql.gz" | docker exec -i "$PGID" psql -U affine -d affine -v ON_ERROR_STOP=1 -q || die "dump load failed"
pq(){  docker exec "$PGID" psql -U affine -d affine -tAF'|' -c "$1"; }
pqn(){ docker exec "$PGID" psql -U affine -d affine -tA     -c "$1"; }
[ "$(pqn "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")" -gt 0 ] || die "empty restored DB"
ok "restored: $(pqn "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'") public tables"

# ===== AC(d) part 1: STATIC scan of the NEW IMAGE's PENDING prisma migrations =====
# Read migrations FROM THE IMAGE (/app/migrations) — the repo working tree differs
# from the image unless it was built from HEAD. Only unambiguous destructive DDL
# hard-fails; plain DELETE/TRUNCATE inside trigger/function bodies is NOT flagged
# (that is covered semantically by the dynamic row-loss + contraction checks below).
# "recorded" = any row in _prisma_migrations (finished OR deliberately rolled-back &
# re-managed by predeploy's fixFailedMigrations). Only truly NEW (unrecorded)
# migrations count as pending — avoids false positives on managed rollbacks.
APPLIED="$(pqn "SELECT migration_name FROM _prisma_migrations")"
IMG_MIGS="$(docker run --rm --entrypoint sh "$NEW_IMAGE" -c 'for d in /app/migrations/*/; do [ -d "$d" ] && basename "$d"; done' 2>/dev/null || true)"   # dirs only (skip migration_lock.toml)
PENDING="$(comm -23 <(printf '%s\n' "$IMG_MIGS" | grep . | sort) <(printf '%s\n' "$APPLIED" | grep . | sort) || true)"
NPEND="$(printf '%s\n' "$PENDING" | grep -c . || true)"
if [ "${NPEND:-0}" -gt 0 ]; then
  log "AC(d): scanning $NPEND pending prisma migration(s) from image $NEW_IMAGE"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    sql="$(docker run --rm --entrypoint sh "$NEW_IMAGE" -c "cat /app/migrations/$n/migration.sql 2>/dev/null" || true)"
    hit="$(printf '%s\n' "$sql" | grep -inE 'DROP TABLE|DROP COLUMN|DROP CONSTRAINT|TRUNCATE +TABLE|RENAME (TO|COLUMN)|ALTER COLUMN .*SET NOT NULL' || true)"
    [ -n "$hit" ] && die "AC(d) DESTRUCTIVE prisma migration in image: $n -> $hit"
  done <<EOF
$PENDING
EOF
else
  log "AC(d): image has no pending prisma migrations vs the restored DB"
fi

# ===== AC(d) part 2: STATIC scan of PENDING TS data migrations (MUST_FIX .4-3) =====
# Only meaningful when the image was built from the current repo HEAD (the compiled
# data migrations inside an arbitrary image differ from the repo .ts sources). For
# any other image the dynamic core-table row-loss check below is the guarantee.
DATA_APPLIED="$(pqn "SELECT name FROM _data_migrations")"
if [ "$NEW_IMAGE" = "woven/affine:$SHORT_SHA" ] && [ -d "$DATA_DIR" ]; then
  for f in "$DATA_DIR"/*.ts; do
    [ -f "$f" ] || continue
    cls="$(grep -oE 'class [A-Za-z0-9_]+' "$f" | head -1 | awk '{print $2}')"
    [ -n "$cls" ] && printf '%s\n' "$DATA_APPLIED" | grep -Fxq "$cls" && continue
    hit="$(grep -inE 'DELETE +FROM|TRUNCATE|DROP +TABLE|DROP +COLUMN' "$f" || true)"
    [ -n "$hit" ] && die "AC(d) DESTRUCTIVE data migration: $(basename "$f") -> $hit"
  done
  log "AC(d): pending TS data migrations scanned (image built from HEAD)"
else
  log "AC(d): TS data-migration static scan skipped (image not built from HEAD) — dynamic row-loss check covers data loss"
fi
ok "AC(d) static scans clean (no destructive pending migration)"

# ---- pre-predeploy baselines (schema + core row counts) -------------------
SCHEMA_PRE="$(pq "SELECT table_name,column_name,is_nullable,data_type FROM information_schema.columns WHERE table_schema='public' ORDER BY 1,2")"
# Guard existence in the SHELL, not in one SQL statement: Postgres plans every table
# reference in a CASE regardless of branch, so a literal missing-table ref errors.
core_counts(){ local t c; for t in users workspaces workspace_user_permissions snapshots blobs user_sessions; do
  if [ "$(pqn "SELECT (to_regclass('public.$t') IS NOT NULL)")" = t ]; then
    c="$(pqn "SELECT count(*) FROM \"$t\"")"
  else c=na; fi
  printf '%s=%s\n' "$t" "$c"
done; }
COUNTS_PRE="$(core_counts)"

# ===== AC(a): predeploy run #1 (NEW image) =====
log "AC(a): predeploy run #1 (NEW=$NEW_IMAGE)…"
dc run --rm affine_migration || die "AC(a) FAIL: predeploy #1 exited non-zero"
COUNTS_A="$(core_counts)"
ok "AC(a): predeploy #1 exit 0"

# MUST_FIX .4-3: row-loss check (restored PRE vs post-predeploy) — fail only on a DECREASE
if command -v python3 >/dev/null 2>&1; then
  python3 - "$COUNTS_PRE" "$COUNTS_A" "${WOVEN_ALLOW_ROWLOSS:-0}" <<'PY' || die "AC(d) FAIL: predeploy REDUCED core-table rows (destructive data migration). Override with WOVEN_ALLOW_ROWLOSS=1"
import sys
pre=dict(l.split('=') for l in sys.argv[1].split('\n') if l)
post=dict(l.split('=') for l in sys.argv[2].split('\n') if l)
allow=sys.argv[3]=='1'
loss=[t for t in pre if pre[t].isdigit() and post.get(t,'').isdigit() and int(post[t])<int(pre[t])]
sys.exit(1 if loss and not allow else 0)
PY
fi

# ===== AC(b): predeploy run #2 must be a no-op =====
log "AC(b): predeploy run #2 (idempotency)…"
PRISMA_A="$(pq  "SELECT migration_name,checksum,finished_at,rolled_back_at,applied_steps_count FROM _prisma_migrations ORDER BY migration_name")"
DATA_A="$(pqn   "SELECT name FROM _data_migrations ORDER BY name")"    # NAME-SET only (always:true row rewrites timestamps)
dc run --rm affine_migration || die "AC(b) FAIL: predeploy #2 exited non-zero (non-idempotent)"
PRISMA_B="$(pq  "SELECT migration_name,checksum,finished_at,rolled_back_at,applied_steps_count FROM _prisma_migrations ORDER BY migration_name")"
DATA_B="$(pqn   "SELECT name FROM _data_migrations ORDER BY name")"
COUNTS_B="$(core_counts)"
SCHEMA_POST="$(pq "SELECT table_name,column_name,is_nullable,data_type FROM information_schema.columns WHERE table_schema='public' ORDER BY 1,2")"
[ "$PRISMA_A" = "$PRISMA_B" ] || { diff <(printf '%s\n' "$PRISMA_A") <(printf '%s\n' "$PRISMA_B") >&2; die "AC(b) FAIL: _prisma_migrations changed on run #2"; }
[ "$DATA_A"   = "$DATA_B"   ] || { comm -13 <(printf '%s\n' "$DATA_A"|sort) <(printf '%s\n' "$DATA_B"|sort) >&2; die "AC(b) FAIL: new/untracked data migration on run #2"; }
[ "$COUNTS_A" = "$COUNTS_B" ] || die "AC(b) FAIL: core row counts changed between runs (mutating data migration)"
[ "$(pqn "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NULL")" = 0 ] || die "AC(b) FAIL: a migration is incomplete (finished_at NULL)"
ok "AC(b): predeploy #2 is a proven no-op"

# ===== AC(d) part 3: DYNAMIC schema-contraction diff (pre vs post) =====
DROPPED="$(comm -23 <(printf '%s\n' "$SCHEMA_PRE"|cut -d'|' -f1,2|sort) <(printf '%s\n' "$SCHEMA_POST"|cut -d'|' -f1,2|sort))"
[ -z "$DROPPED" ] || die "AC(d) FAIL: predeploy dropped existing table/column(s): $DROPPED"
NEWNN="$(join -t'|' -1 1 -2 1 \
  <(printf '%s\n' "$SCHEMA_PRE" |awk -F'|' '$3=="YES"{print $1"."$2}'|sort) \
  <(printf '%s\n' "$SCHEMA_POST"|awk -F'|' '$3=="NO"{print $1"."$2}' |sort) || true)"
[ -z "$NEWNN" ] || die "AC(d) FAIL: existing column(s) became NOT NULL (old writers break): $NEWNN"
ok "AC(d): no schema contraction (no dropped col/table, no new NOT NULL)"

# ===== AC(c): PREVIOUS image boots on NEW schema, READ + WRITE =====
log "AC(c): booting PREV image on migrated schema…"
export AFFINE_IMAGE="$PREV_IMAGE"; dc up -d affine    # affine has no migration dep in this compose -> predeploy NOT re-run
URL="http://localhost:$RESTORE_PORT"
ok_boot=0
for i in $(seq 1 45); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$URL/info" 2>/dev/null || echo 000)"
  [ "$code" -ge 200 ] && [ "$code" -lt 400 ] && { ok_boot=1; break; }; sleep 2
done
[ "$ok_boot" = 1 ] || { dc logs --tail 40 affine >&2; die "AC(c) FAIL: PREV image did not boot on new schema"; }
# READ probe
R="$(curl -s -X POST "$URL/graphql" -H 'content-type: application/json' -d '{"query":"{ serverConfig { version } }"}')"
printf '%s' "$R" | grep -q '"version"' && ! printf '%s' "$R" | grep -q '"errors"' || die "AC(c) FAIL: read (serverConfig) failed: $R"
VER="$(printf '%s' "$R" | sed -E 's/.*"version":"([^"]+)".*/\1/')"
ok "AC(c): PREV image reads new schema (serverConfig.version=$VER)"

# WRITE probe: seed a user (argon2 hash from PREV image, no pepper) -> sign-in -> user_sessions row
PW="woven-rehearse-$RANDOM$RANDOM"; EMAIL="woven-rehearse-$TS@local.invalid"
HASH="$(docker run --rm --entrypoint node -w /app "$PREV_IMAGE" -e \
  'const a=(()=>{try{return require("@node-rs/argon2")}catch(e){return require("/app/dist/node_modules/@node-rs/argon2")}})();a.hash(process.argv[1]).then(h=>process.stdout.write(h)).catch(e=>{console.error(e);process.exit(1)})' "$PW" 2>/dev/null || true)"
[ -n "$HASH" ] || die "AC(c) FAIL: could not compute argon2 hash in PREV image"
# seed the user (MUST_FIX .4-1: no readonly UID var; verify by email, not a captured id)
pqn "INSERT INTO users (id,name,email,email_verified,password,registered,disabled,created_at)
  VALUES (gen_random_uuid()::text,'woven-rehearsal','$EMAIL',now(),'$HASH',true,false,now())" >/dev/null 2>&1 \
  || die "AC(c) FAIL: could not seed user"
[ "$(pqn "SELECT count(*) FROM users WHERE email='$EMAIL'")" = 1 ] || die "AC(c) FAIL: seeded user not found"
code="$(curl -s -o "$SCRATCH/signin.json" -w '%{http_code}' -X POST "$URL/api/auth/sign-in" \
  -H 'content-type: application/json' -H "x-affine-version: $VER" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}")"
[ "$code" = 200 ] || { cat "$SCRATCH/signin.json" >&2; die "AC(c) FAIL: sign-in (server WRITE) rejected (HTTP $code)"; }
# The PREV server must have PERSISTED a session row against the new schema (join by
# email — robust to psql RETURNING capture quirks).
SESS="$(pqn "SELECT count(*) FROM user_sessions us JOIN users u ON u.id=us.user_id WHERE u.email='$EMAIL'")"
[ "${SESS:-0}" -ge 1 ] || die "AC(c) FAIL: server did not persist a user_sessions row (write path broken)"
ok "AC(c): PREV image WROTE new schema (sign-in persisted a user_sessions row)"

# ===== record rehearsal-pass token bound to the CANDIDATE image id =====
mkdir -p "$SCRIPT_DIR/.woven-rehearsed"
NEW_ID="$(docker inspect "$NEW_IMAGE" --format '{{.Id}}' | sed 's/sha256://')"
printf 'image=%s\nimage_id=%s\nprev=%s\ngit_sha=%s\nts=%s\n' "$NEW_IMAGE" "$NEW_ID" "$PREV_IMAGE" "$SHORT_SHA" "$TS" \
  > "$SCRIPT_DIR/.woven-rehearsed/$NEW_ID"

ok "MIGRATION REHEARSAL PASSED — idempotent, no destructive/contract migration, PREV image reads+writes the new schema."
log "rehearsal token: scripts/.woven-rehearsed/$NEW_ID"
