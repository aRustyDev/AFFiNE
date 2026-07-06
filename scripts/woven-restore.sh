#!/usr/bin/env bash
#
# woven-restore.sh — rehearse restoring a woven-backup into a throwaway stack.
#
# Proves a backup is complete & usable: spins an ISOLATED scratch AFFiNE stack
# (own project/volumes/port, indexer off), loads the pg_dump + blobs + config,
# runs the real self-host predeploy (prisma migrate deploy + data migrations),
# then boots the server and asserts it answers. Tears everything down after.
#
# THIS IS A DRILL: it never touches the live 'affine' stack or its data.
# See .beads/woven-cd-gate.md §7 (bead affine-4yo.3).
#
# Usage:   scripts/woven-restore.sh [BACKUP_DIR]      # default: newest backup
# Env:
#   WOVEN_BACKUP_DIR    where backups live      (default: $HOME/.affine/backups)
#   WOVEN_RESTORE_DIR   scratch root            (default: $HOME/.affine/restore-drill)
#   WOVEN_RESTORE_PROJECT compose project name  (default: affine_restore_drill)
#   WOVEN_RESTORE_PORT  host port for the server(default: 3011)
#   WOVEN_AFFINE_IMAGE  server/migration image  (default: live image, else :stable)
#   WOVEN_KEEP=1        keep the stack + scratch running for inspection (no teardown)
#
set -euo pipefail

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[woven-restore]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[woven-restore] ✔${c_rst} $*"; }
warn() { printf '%s\n' "${c_ylw}[woven-restore] ⚠${c_rst} $*" >&2; }
die()  { printf '%s\n' "${c_red}[woven-restore] ✗${c_rst} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/woven-restore.compose.yml"
[ -f "$COMPOSE_FILE" ] || die "missing scratch compose file: $COMPOSE_FILE"

BACKUP_ROOT="${WOVEN_BACKUP_DIR:-$HOME/.affine/backups}"
SCRATCH_ROOT="${WOVEN_RESTORE_DIR:-$HOME/.affine/restore-drill}"
PROJECT="${WOVEN_RESTORE_PROJECT:-affine_restore_drill}"
export RESTORE_PORT="${WOVEN_RESTORE_PORT:-3011}"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

# ---- resolve backup dir ---------------------------------------------------
BACKUP_DIR="${1:-}"
if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"
  [ -n "$BACKUP_DIR" ] || die "no backups found under $BACKUP_ROOT — run scripts/woven-backup.sh first"
fi
BACKUP_DIR="${BACKUP_DIR%/}"
DB_ARTIFACT="$BACKUP_DIR/affine-db.sql.gz"
STORAGE_ARTIFACT="$BACKUP_DIR/storage.tar.gz"
CONFIG_ARTIFACT="$BACKUP_DIR/config.tar.gz"
for f in "$DB_ARTIFACT" "$STORAGE_ARTIFACT" "$CONFIG_ARTIFACT"; do
  [ -f "$f" ] || die "backup artifact missing: $f"
done
log "restoring from: $BACKUP_DIR"

# ---- port free? -----------------------------------------------------------
if lsof -nP -iTCP:"$RESTORE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "host port $RESTORE_PORT is in use; set WOVEN_RESTORE_PORT to a free port"
fi

# ---- scratch layout -------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
SCRATCH="$SCRATCH_ROOT/$TS"
export DB_DATA_LOCATION="$SCRATCH/pgdata"
export UPLOAD_LOCATION="$SCRATCH/storage"
export CONFIG_LOCATION="$SCRATCH/config"
mkdir -p "$DB_DATA_LOCATION" "$SCRATCH/_x"
# Each archive is rooted at a single top-level dir (basename of the live mount);
# extract, then move that dir into place as $UPLOAD_LOCATION / $CONFIG_LOCATION.
extract_to() { # <artifact> <dest>
  local top
  top="$(tar -tzf "$1" | head -1 | cut -d/ -f1)"
  [ -n "$top" ] || die "empty archive: $1"
  tar -xzf "$1" -C "$SCRATCH/_x"
  rm -rf "$2"; mv "$SCRATCH/_x/$top" "$2"
}
extract_to "$STORAGE_ARTIFACT" "$UPLOAD_LOCATION"
extract_to "$CONFIG_ARTIFACT"  "$CONFIG_LOCATION"
rm -rf "$SCRATCH/_x"
[ -f "$CONFIG_LOCATION/private.key" ] || die "restored config is missing private.key"
ok "scratch prepared at $SCRATCH"

# ---- scratch DB credentials (throwaway; dump is --no-owner) ---------------
export DB_USERNAME=affine
export DB_PASSWORD=affine
export DB_DATABASE=affine
# match the image that produced the data when possible
if [ -n "${WOVEN_AFFINE_IMAGE:-}" ]; then
  export AFFINE_IMAGE="$WOVEN_AFFINE_IMAGE"
else
  # Prefer the exact image the live deployment runs (resolved by identity), so the
  # drill matches the binary that produced the data; fall back to :stable.
  AFFINE_IMAGE=""
  if [ -f "$SCRIPT_DIR/woven-resolve-live.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/woven-resolve-live.sh"
    woven_resolve_live >/dev/null 2>&1 && AFFINE_IMAGE="$LIVE_IMAGE_REF"
  fi
  export AFFINE_IMAGE="${AFFINE_IMAGE:-ghcr.io/toeverything/affine:stable}"
fi
log "scratch image: $AFFINE_IMAGE   port: $RESTORE_PORT   project: $PROJECT"

dc() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

# ---- teardown trap --------------------------------------------------------
cleanup() {
  local code=$?
  if [ "${WOVEN_KEEP:-0}" = "1" ]; then
    warn "WOVEN_KEEP=1 — leaving stack '$PROJECT' up on port $RESTORE_PORT and scratch at $SCRATCH"
    warn "teardown manually:  docker compose -p $PROJECT -f $COMPOSE_FILE down -v && rm -rf '$SCRATCH'"
  else
    log "tearing down scratch stack…"
    dc down -v >/dev/null 2>&1 || true
    rm -rf "$SCRATCH" 2>/dev/null || true
  fi
  exit $code
}
trap cleanup EXIT

# ---- 1. bring up postgres + redis ----------------------------------------
log "starting scratch postgres + redis…"
dc up -d postgres redis
PGID="$(dc ps -q postgres)"
[ -n "$PGID" ] || die "scratch postgres did not start"
log "waiting for postgres health…"
for i in $(seq 1 40); do
  st="$(docker inspect "$PGID" --format '{{.State.Health.Status}}' 2>/dev/null || echo none)"
  [ "$st" = "healthy" ] && break
  sleep 2
done
[ "$(docker inspect "$PGID" --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ] \
  || die "scratch postgres never became healthy"
ok "scratch postgres healthy"

# ---- 2. load the logical dump --------------------------------------------
log "loading pg_dump…"
set -o pipefail
if ! gzip -dc "$DB_ARTIFACT" | docker exec -i "$PGID" psql -U "$DB_USERNAME" -d "$DB_DATABASE" -v ON_ERROR_STOP=1 -q; then
  die "restoring the dump failed (see errors above)"
fi
TABLES="$(docker exec "$PGID" psql -U "$DB_USERNAME" -d "$DB_DATABASE" -tAc "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d '[:space:]')"
[ "${TABLES:-0}" -gt 0 ] || die "restored DB has no public tables"
ok "dump loaded: $TABLES public tables"

# ---- 3. run the real predeploy (migrations must be a clean no-op) ----------
log "running self-host predeploy (migrate deploy + data migrations)…"
if ! dc run --rm affine_migration; then
  die "affine_migration exited non-zero against the restored schema"
fi
ok "predeploy exited 0"

# ---- 4. boot server and assert it answers --------------------------------
log "booting scratch server…"
dc up -d affine
URL="http://localhost:$RESTORE_PORT"
healthy=0
for i in $(seq 1 45); do
  for path in /info /; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$URL$path" 2>/dev/null || echo 000)"
    if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then healthy=1; break; fi
  done
  [ "$healthy" = "1" ] && break
  sleep 2
done
if [ "$healthy" != "1" ]; then
  warn "server did not answer on $URL within timeout; recent logs:"
  dc logs --tail 40 affine >&2 || true
  die "restored instance failed to become healthy"
fi
ok "restored server answering at $URL (HTTP $code)"

ok "RESTORE DRILL PASSED — backup at $BACKUP_DIR is complete and restorable."
