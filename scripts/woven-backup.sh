#!/usr/bin/env bash
#
# woven-backup.sh — pre-deploy backup of the live self-hosted AFFiNE instance.
#
# Captures everything needed to fully reconstruct the instance:
#   * PostgreSQL logical dump (pg_dump, gzipped)  — NOT a copy of live pgdata
#   * blob storage (/root/.affine/storage)  — tar.gz (bind OR named volume)
#   * config (/root/.affine/config, incl. private.key)  — tar.gz (bind OR named volume)
#   * manifest.txt with checksums, sizes, and provenance
#
# Sources are derived from the RUNNING containers (docker inspect / printenv), so
# the script is correct regardless of what the compose .env claims on disk. Works
# against both the legacy bind-mount stack and the woven-local named-volume stack.
# Pair with scripts/woven-resolve-live.sh to pass the correct containers, e.g.:
#   . scripts/woven-resolve-live.sh; woven_resolve_live
#   WOVEN_PG_CONTAINER="$LIVE_PG" WOVEN_SERVER_CONTAINER="$LIVE_SERVER" \
#     WOVEN_DB_USER=affine WOVEN_DB_NAME=affine scripts/woven-backup.sh
# See .beads/woven-cd-gate.md §7/§9 (bead affine-4yo.3).
#
# Usage:   scripts/woven-backup.sh
# Env:
#   WOVEN_BACKUP_DIR       root for timestamped backups (default: $HOME/.affine/backups)
#   WOVEN_PG_CONTAINER     live postgres container       (default: affine_postgres)
#   WOVEN_SERVER_CONTAINER live server container         (default: affine_server)
#   WOVEN_DB_USER/NAME     app DB user/name override (else parsed from DATABASE_URL)
#   WOVEN_RETENTION        keep newest N backups         (default: 14)
#
set -euo pipefail

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[woven-backup]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[woven-backup] ✔${c_rst} $*"; }
warn() { printf '%s\n' "${c_ylw}[woven-backup] ⚠${c_rst} $*" >&2; }
die()  { printf '%s\n' "${c_red}[woven-backup] ✗${c_rst} $*" >&2; exit 1; }

BACKUP_ROOT="${WOVEN_BACKUP_DIR:-$HOME/.affine/backups}"
PG_CONTAINER="${WOVEN_PG_CONTAINER:-affine_postgres}"
SERVER_CONTAINER="${WOVEN_SERVER_CONTAINER:-affine_server}"
RETENTION="${WOVEN_RETENTION:-14}"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || die "live postgres container '$PG_CONTAINER' not found (is the stack up?)"

# ---- resolve the source container (server preferred; fall back to migration job) ----
SRC_CONTAINER="$SERVER_CONTAINER"
docker inspect "$SRC_CONTAINER" >/dev/null 2>&1 || \
  SRC_CONTAINER="$(docker inspect affine_migration_job >/dev/null 2>&1 && echo affine_migration_job || echo "$PG_CONTAINER")"
SERVER_IMAGE="$(docker inspect "$SRC_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
[ -n "$SERVER_IMAGE" ] || SERVER_IMAGE="$(docker inspect "$PG_CONTAINER" --format '{{.Config.Image}}')"

# ---- derive DB identity: WOVEN_DB_* override -> server DATABASE_URL -> POSTGRES_* ----
# The shared multi-tenant postgres has an empty POSTGRES_DB, so parse the app's
# DATABASE_URL (postgresql://user:pass@host/db) from the server container.
DBURL="$(docker exec "$SRC_CONTAINER" printenv DATABASE_URL 2>/dev/null || true)"
DBUSER="${WOVEN_DB_USER:-$(printf '%s' "$DBURL" | sed -E 's#^[a-z]+://([^:]+):.*#\1#')}"
DBNAME="${WOVEN_DB_NAME:-$(printf '%s' "$DBURL" | sed -E 's#.*/([^/?]+)([?].*)?$#\1#')}"
[ -n "$DBUSER" ] || DBUSER="$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER 2>/dev/null || true)"
[ -n "$DBNAME" ] || DBNAME="$(docker exec "$PG_CONTAINER" printenv POSTGRES_DB   2>/dev/null || true)"
[ -n "$DBUSER" ] || die "could not resolve DB user (set WOVEN_DB_USER)"
[ -n "$DBNAME" ] || die "could not resolve DB name (set WOVEN_DB_NAME)"

# ---- resolve blob/config mounts (bind OR named volume) --------------------
# describe_mount -> "type|name|source" for a destination on SRC_CONTAINER
describe_mount() { # <container> <destination>
  docker inspect "$1" --format \
    "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}" 2>/dev/null
}
STORAGE_MNT="$(describe_mount "$SRC_CONTAINER" /root/.affine/storage)"
CONFIG_MNT="$(describe_mount "$SRC_CONTAINER" /root/.affine/config)"
[ -n "$STORAGE_MNT" ] || die "could not resolve storage mount from $SRC_CONTAINER"
[ -n "$CONFIG_MNT" ]  || die "could not resolve config mount from $SRC_CONTAINER"

# tar a mount into an archive ROOTED AT <top> (so woven-restore.sh extract_to works).
# Named volumes are tarred via a helper container (the volume _data path is not
# host-readable under OrbStack); bind mounts are tarred directly on the host.
tar_mount() { # <mount_desc: type|name|source> <top: storage|config> <out.tar.gz>
  local desc="$1" top="$2" out="$3" typ name src rest
  typ="${desc%%|*}"; rest="${desc#*|}"; name="${rest%%|*}"; src="${rest#*|}"
  if [ "$typ" = volume ] && [ -n "$name" ]; then
    docker run --rm --entrypoint tar \
      -v "$name":/m/"$top":ro -v "$(cd "$(dirname "$out")" && pwd)":/out \
      "$SERVER_IMAGE" -czf /out/"$(basename "$out")" -C /m "$top"
  elif [ "$typ" = bind ] && [ -d "$src" ]; then
    tar -czf "$out" -C "$(dirname "$src")" "$(basename "$src")"
  else
    die "cannot tar mount (type=$typ name=$name src=$src)"
  fi
}

# ---- private.key precheck (bind or volume) --------------------------------
config_has_key() {
  local typ name src rest; typ="${CONFIG_MNT%%|*}"; rest="${CONFIG_MNT#*|}"; name="${rest%%|*}"; src="${rest#*|}"
  if [ "$typ" = volume ] && [ -n "$name" ]; then
    docker run --rm -v "$name":/c:ro --entrypoint test "$SERVER_IMAGE" -f /c/private.key
  else
    [ -f "$src/private.key" ]
  fi
}
config_has_key || die "private.key missing in config mount — refusing an incomplete backup"

# ---- destination ----------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$TS"
mkdir -p "$DEST"
log "backup → $DEST"
log "  db=$DBNAME user=$DBUSER pg=$PG_CONTAINER src=$SRC_CONTAINER"
log "  storage=$STORAGE_MNT"
log "  config=$CONFIG_MNT"

# ---- 1. postgres logical dump --------------------------------------------
# --clean --if-exists → restore is idempotent into a fresh or existing DB.
DB_ARTIFACT="$DEST/affine-db.sql.gz"
log "pg_dump…"
set -o pipefail
docker exec "$PG_CONTAINER" pg_dump -U "$DBUSER" -d "$DBNAME" \
  --clean --if-exists --no-owner --no-privileges \
  | gzip -9 > "$DB_ARTIFACT"
gzip -t "$DB_ARTIFACT" || die "db dump failed gzip integrity check"
# sanity: the dump must contain the pg_dump header once decompressed.
# (grep -qm1 exits on first match; disable pipefail so gzip's SIGPIPE isn't fatal.)
set +o pipefail
gzip -dc "$DB_ARTIFACT" 2>/dev/null | grep -qm1 "PostgreSQL database dump" && hdr_ok=1 || hdr_ok=0
set -o pipefail
[ "$hdr_ok" = 1 ] || die "db dump does not look like a pg_dump (empty/garbage)?"
ok "db dump: $(du -h "$DB_ARTIFACT" | cut -f1)"

# ---- 2. blob storage ------------------------------------------------------
STORAGE_ARTIFACT="$DEST/storage.tar.gz"
log "tar storage…"
tar_mount "$STORAGE_MNT" storage "$STORAGE_ARTIFACT"
gzip -t "$STORAGE_ARTIFACT" || die "storage tar failed gzip integrity check"
ok "storage: $(du -h "$STORAGE_ARTIFACT" | cut -f1)"

# ---- 3. config (incl. private.key) ---------------------------------------
CONFIG_ARTIFACT="$DEST/config.tar.gz"
log "tar config…"
tar_mount "$CONFIG_MNT" config "$CONFIG_ARTIFACT"
gzip -t "$CONFIG_ARTIFACT" || die "config tar failed gzip integrity check"
tar -tzf "$CONFIG_ARTIFACT" | grep -q 'private.key' || die "private.key not present in config tar"
ok "config: $(du -h "$CONFIG_ARTIFACT" | cut -f1)"

# ---- 4. manifest ----------------------------------------------------------
MANIFEST="$DEST/manifest.txt"
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
{
  echo "woven-backup manifest"
  echo "timestamp:        $TS"
  echo "db_name:          $DBNAME"
  echo "db_user:          $DBUSER"
  echo "pg_container:     $PG_CONTAINER"
  echo "server_image:     $SERVER_IMAGE"
  echo "src_container:    $SRC_CONTAINER"
  echo "storage_mount:    $STORAGE_MNT"
  echo "config_mount:     $CONFIG_MNT"
  echo "affine-db.sql.gz  sha256=$(sha "$DB_ARTIFACT")  bytes=$(wc -c < "$DB_ARTIFACT")"
  echo "storage.tar.gz    sha256=$(sha "$STORAGE_ARTIFACT")  bytes=$(wc -c < "$STORAGE_ARTIFACT")"
  echo "config.tar.gz     sha256=$(sha "$CONFIG_ARTIFACT")  bytes=$(wc -c < "$CONFIG_ARTIFACT")"
} > "$MANIFEST"
cat "$MANIFEST"

# ---- 5. retention ---------------------------------------------------------
if [ "$RETENTION" -gt 0 ]; then
  # bash 3.2 safe (macOS default bash has no mapfile): count + head, oldest first.
  count="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${count:-0}" -gt "$RETENTION" ]; then
    prune=$(( count - RETENTION ))
    log "retention: pruning $prune old backup(s) (keeping newest $RETENTION)"
    ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | head -n "$prune" | while IFS= read -r d; do
      warn "pruning $d"
      rm -rf "$d"
    done
  fi
fi

ok "BACKUP COMPLETE → $DEST"
echo "Restore drill:  scripts/woven-restore.sh \"$DEST\""
