#!/usr/bin/env bash
#
# woven-promote.sh — staged, gated promotion of an AFFiNE fork image to the live
# woven-local stack, with rollback. Live target resolved BY IDENTITY (never by an
# assumed name) via woven-resolve-live.sh.
#
#   stage     build/pick candidate -> (if it introduces migrations) run the .4
#             rehearsal gate -> backup -> seed an ISOLATED staging stack from the
#             newest prod snapshot -> run predeploy (indexer ON, prod parity) ->
#             boot -> health-check on :3020. Records a staged-image marker.
#   prod      promote the STAGED candidate to live: re-derive the schema signal
#             from image-vs-live-DB (never trusts a flag), require a rehearsal token
#             bound to the image id for schema-changing releases, take a MANDATORY
#             fresh backup, typed confirmation, flip AFFINE_IMAGE in <live>/.env,
#             recreate the live affine service, health-check the live container.
#   rollback  restore the previous AFFINE_IMAGE (image-only by default; --db also
#             restores DB+blobs from the pre-promote backup, private-key-safe).
#
# One-time setup (see woven-cd-runbook.md): add an AFFINE_IMAGE override to the live
# services/affine.yaml. Prod refuses to run until that override is present.
# See .beads/woven-cd-gate.md §9 (bead affine-4yo.5). PROD/ROLLBACK edit live infra.
#
# Usage:
#   scripts/woven-promote.sh stage    [--image REF] [--skip-backup] [--seed-from DIR]
#   scripts/woven-promote.sh prod     [--image REF] [--dry-run]
#   scripts/woven-promote.sh rollback [--db]
#
set -euo pipefail
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[woven-promote]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[woven-promote] ✔${c_rst} $*"; }
warn() { printf '%s\n' "${c_ylw}[woven-promote] ⚠${c_rst} $*" >&2; }
die()  { printf '%s\n' "${c_red}[woven-promote] ✗${c_rst} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; SCRIPT_DIR="$REPO_ROOT/scripts"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/woven-resolve-live.sh"
command -v docker >/dev/null 2>&1 || die "docker not found"

STAGING_PROJECT="${WOVEN_STAGING_PROJECT:-affine_staging}"
STAGING_COMPOSE="$SCRIPT_DIR/woven-staging.compose.yml"
STAGING_ENV="$SCRIPT_DIR/woven-staging.env"
STAGING_ROOT="${WOVEN_STAGING_ROOT:-$HOME/.affine/staging}"
BACKUP_ROOT="${WOVEN_BACKUP_DIR:-$HOME/.affine/backups}"
STAGED_MARK="$SCRIPT_DIR/.woven-staged-image"
ROLLBACK_MARK="$SCRIPT_DIR/.woven-prod-rollback"
REHEARSED_DIR="$SCRIPT_DIR/.woven-rehearsed"
STAGING_PORT="${STAGING_PORT:-3020}"

TS="$(date +%Y%m%d-%H%M%S)"
SUB="${1:-}"; shift || true
IMAGE=""; DRY_RUN=0; SKIP_BACKUP=0; SEED_FROM=""; DB_RESTORE=0
while [ $# -gt 0 ]; do case "$1" in
  --image) IMAGE="$2"; shift 2;;
  --dry-run) DRY_RUN=1; shift;;
  --skip-backup) SKIP_BACKUP=1; shift;;
  --seed-from) SEED_FROM="$2"; shift 2;;
  --db) DB_RESTORE=1; shift;;
  *) die "unknown flag: $1";;
esac; done

dcs(){ docker compose -p "$STAGING_PROJECT" -f "$STAGING_COMPOSE" --env-file "$STAGING_ENV" "$@"; }
img_id(){ docker inspect "$1" --format '{{.Id}}' 2>/dev/null | sed 's/sha256://'; }
get_env_var(){ grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
set_env_var(){ local f="$1" k="$2" v="$3" t; t="$(mktemp)"; grep -v -E "^${k}=" "$f" 2>/dev/null >"$t" || true; printf '%s=%s\n' "$k" "$v" >>"$t"; chmod 600 "$t"; mv "$t" "$f"; }
confirm(){ local a; printf '%s\n' "${c_ylw}Type EXACTLY to proceed:${c_rst} $1" >&2; read -r a < /dev/tty 2>/dev/null || die "no TTY for confirmation (refusing)"; [ "$a" = "$1" ] || die "confirmation mismatch — aborted"; }
wait_health_container(){ local i; for i in $(seq 1 60); do [ "$(docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && return 0; sleep 3; done; return 1; }
wait_http(){ local url="$1" i code; for i in $(seq 1 60); do code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null || echo 000)"; [ "$code" -ge 200 ] && [ "$code" -lt 400 ] && return 0; sleep 3; done; return 1; }

# nonempty output => the image ships prisma migrations NOT recorded in the live DB
pending_migrations(){ # <candidate-image>
  local applied imgm
  applied="$(docker exec "$LIVE_PG" psql -U affine -d affine -tA -c "SELECT migration_name FROM _prisma_migrations" 2>/dev/null || true)"
  imgm="$(docker run --rm --entrypoint sh "$1" -c 'for d in /app/migrations/*/; do [ -d "$d" ] && basename "$d"; done' 2>/dev/null || true)"   # dirs only (skip migration_lock.toml)
  comm -23 <(printf '%s\n' "$imgm" | grep . | sort) <(printf '%s\n' "$applied" | grep . | sort)
}

write_staging_env(){ # <candidate-image>
  cat > "$STAGING_ENV" <<EOF
AFFINE_IMAGE=$1
STAGING_PORT=$STAGING_PORT
STAGING_PG_PORT=${STAGING_PG_PORT:-5442}
STAGING_REDIS_PORT=${STAGING_REDIS_PORT:-6389}
DB_USERNAME=affine
DB_PASSWORD=affine
DB_DATABASE=affine
DB_DATA_LOCATION=$STAGING_ROOT/pgdata
UPLOAD_LOCATION=$STAGING_ROOT/storage
CONFIG_LOCATION=$STAGING_ROOT/config
EOF
  chmod 600 "$STAGING_ENV"
}
extract_to(){ local art="$1" dest="$2" tmp="$3" top; top="$(tar -tzf "$art"|head -1|cut -d/ -f1)"; [ -n "$top" ]||die "empty archive $art"; rm -rf "$tmp"; mkdir -p "$tmp"; tar -xzf "$art" -C "$tmp"; rm -rf "$dest"; mv "$tmp/$top" "$dest"; rm -rf "$tmp"; }

# ==========================================================================
case "$SUB" in
# --------------------------------------------------------------------- STAGE
stage)
  woven_resolve_live
  CANDIDATE="${IMAGE:-$("$SCRIPT_DIR/woven-build-image.sh")}"
  [ -n "$CANDIDATE" ] || die "no candidate image"
  docker image inspect "$CANDIDATE" >/dev/null 2>&1 || die "candidate '$CANDIDATE' not present locally"
  case "$CANDIDATE" in *-dirty) die "refuse to stage a *-dirty image (built from an uncommitted tree)";; esac
  lsof -nP -iTCP:"$STAGING_PORT" -sTCP:LISTEN >/dev/null 2>&1 && die "staging port $STAGING_PORT busy"
  IMG_ID="$(img_id "$CANDIDATE")"
  log "candidate: $CANDIDATE ($IMG_ID)"

  # schema signal computed UNCONDITIONALLY (MUST_FIX .5-1)
  SCHEMA=0; [ -n "$(pending_migrations "$CANDIDATE")" ] && SCHEMA=1
  if [ "$SCHEMA" = 1 ]; then
    log "candidate introduces migration(s) not in live DB -> running .4 rehearsal gate…"
    WOVEN_REHEARSAL_IMAGE="$CANDIDATE" "$SCRIPT_DIR/woven-migration-rehearsal.sh" || die "rehearsal (.4) FAILED — aborting stage"
    [ -f "$REHEARSED_DIR/$IMG_ID" ] || die "no rehearsal token for candidate image id — abort"
    ok "rehearsal passed (token: .woven-rehearsed/$IMG_ID)"
  else
    log "candidate introduces no new migrations vs live DB — .4 rehearsal not required"
  fi

  # backup live + pick seed snapshot
  if [ "$SKIP_BACKUP" != 1 ]; then
    WOVEN_PG_CONTAINER="$LIVE_PG" WOVEN_SERVER_CONTAINER="$LIVE_SERVER" \
      WOVEN_DB_USER=affine WOVEN_DB_NAME=affine "$SCRIPT_DIR/woven-backup.sh"
  fi
  BACKUP="${SEED_FROM:-$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)}"
  BACKUP="${BACKUP%/}"
  [ -n "$BACKUP" ] || die "no backup to seed staging from (run without --skip-backup, or pass --seed-from)"
  for f in affine-db.sql.gz storage.tar.gz config.tar.gz; do [ -f "$BACKUP/$f" ] || die "seed backup missing $f"; done
  log "seeding staging from $BACKUP"

  write_staging_env "$CANDIDATE"
  dcs down -v >/dev/null 2>&1 || true
  rm -rf "$STAGING_ROOT"; mkdir -p "$STAGING_ROOT/pgdata"
  extract_to "$BACKUP/storage.tar.gz" "$STAGING_ROOT/storage" "$STAGING_ROOT/_x"
  extract_to "$BACKUP/config.tar.gz"  "$STAGING_ROOT/config"  "$STAGING_ROOT/_x"
  [ -f "$STAGING_ROOT/config/private.key" ] || die "seed config missing private.key"

  dcs up -d postgres redis manticore
  SPG="$(dcs ps -q postgres)"; [ -n "$SPG" ] || die "staging postgres did not start"
  for i in $(seq 1 40); do [ "$(docker inspect "$SPG" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break; sleep 2; done
  [ "$(docker inspect "$SPG" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] || die "staging postgres unhealthy"
  gzip -dc "$BACKUP/affine-db.sql.gz" | docker exec -i "$SPG" psql -U affine -d affine -v ON_ERROR_STOP=1 -q || die "staging dump load failed"

  log "running staging predeploy + boot (indexer ON, prod parity)…"
  dcs up -d affine || die "staging predeploy/boot failed"    # affine dep runs affine_migration first
  wait_http "http://localhost:$STAGING_PORT/info" || { dcs logs --tail 40 affine >&2; die "staging server did not become healthy on :$STAGING_PORT"; }

  printf 'image=%s\nimage_id=%s\nschema=%s\nseed=%s\nts=%s\n' "$CANDIDATE" "$IMG_ID" "$SCHEMA" "$BACKUP" "$TS" > "$STAGED_MARK"
  ok "STAGED $CANDIDATE at http://localhost:$STAGING_PORT — verify it, then: scripts/woven-promote.sh prod"
  ;;

# ---------------------------------------------------------------------- PROD
prod)
  woven_resolve_live
  CANDIDATE="${IMAGE:-$(get_env_var "$STAGED_MARK" image)}"
  [ -n "$CANDIDATE" ] || die "no candidate; run 'stage' first or pass --image"
  STAGED_IMG="$(get_env_var "$STAGED_MARK" image)"
  [ "$STAGED_IMG" = "$CANDIDATE" ] || die "candidate '$CANDIDATE' was not the last staged image ('$STAGED_IMG') — run: scripts/woven-promote.sh stage --image $CANDIDATE"
  case "$CANDIDATE" in *-dirty) die "refuse to promote a *-dirty image";; esac
  docker image inspect "$CANDIDATE" >/dev/null 2>&1 || die "candidate image '$CANDIDATE' absent locally"
  IMG_ID="$(img_id "$CANDIDATE")"

  # one-time setup must be present
  AFF_SVC="$LIVE_DIR/services/affine.yaml"
  [ -f "$AFF_SVC" ] || die "cannot find live service file: $AFF_SVC"
  grep -q 'AFFINE_IMAGE' "$AFF_SVC" || die "one-time setup missing: add an \${AFFINE_IMAGE:-...} override to $AFF_SVC (see woven-cd-runbook.md)"

  # PROD RE-DERIVES the schema signal (never trusts the staged flag) — MUST_FIX .5-1
  if [ -n "$(pending_migrations "$CANDIDATE")" ]; then
    [ -f "$REHEARSED_DIR/$IMG_ID" ] || die "schema-changing release has NO rehearsal token for image id $IMG_ID — run 'stage' (.4) first"
    log "schema-changing release; rehearsal token present ✓"
  fi

  LIVE_ENV="$LIVE_DIR/.env"
  [ -f "$LIVE_ENV" ] || die "live env not found: $LIVE_ENV"
  PREV_IMAGE="$(get_env_var "$LIVE_ENV" AFFINE_IMAGE)"; [ -n "$PREV_IMAGE" ] || PREV_IMAGE="$LIVE_IMAGE_REF"
  PREV_ID="$LIVE_IMAGE_ID"
  log "live=$LIVE_SERVER project=$LIVE_PROJECT"
  log "AFFINE_IMAGE: $PREV_IMAGE  ->  $CANDIDATE"

  # mandatory fresh backup of CURRENT live
  if [ "$DRY_RUN" != 1 ]; then
    WOVEN_PG_CONTAINER="$LIVE_PG" WOVEN_SERVER_CONTAINER="$LIVE_SERVER" \
      WOVEN_DB_USER=affine WOVEN_DB_NAME=affine "$SCRIPT_DIR/woven-backup.sh"
  fi
  BACKUP="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"; BACKUP="${BACKUP%/}"
  printf 'prev_image=%s\nprev_id=%s\nbackup=%s\ncandidate=%s\nts=%s\n' "$PREV_IMAGE" "$PREV_ID" "$BACKUP" "$CANDIDATE" "$TS" > "$ROLLBACK_MARK"

  if [ "$DRY_RUN" = 1 ]; then
    log "(dry-run) would: cp $LIVE_ENV .bak; set AFFINE_IMAGE=$CANDIDATE; docker compose -p $LIVE_PROJECT up -d affine; health-check $LIVE_SERVER"
    ok "(dry-run) no live writes performed"; exit 0
  fi

  confirm "promote ${CANDIDATE##*:} to prod"
  cp "$LIVE_ENV" "$LIVE_ENV.bak.$TS"; chmod 600 "$LIVE_ENV.bak.$TS"
  set_env_var "$LIVE_ENV" AFFINE_IMAGE_PREV "$PREV_IMAGE"
  set_env_var "$LIVE_ENV" AFFINE_IMAGE "$CANDIDATE"

  FARGS=(); oldIFS=$IFS; IFS=,; for f in $LIVE_COMPOSE; do FARGS+=(-f "$f"); done; IFS=$oldIFS
  docker compose --project-directory "$LIVE_DIR" --env-file "$LIVE_ENV" -p "$LIVE_PROJECT" "${FARGS[@]}" up -d affine \
    || die "live 'up -d affine' failed — run: scripts/woven-promote.sh rollback"
  woven_resolve_live   # container recreated (same name)
  wait_health_container "$LIVE_SERVER" || die "PROD UNHEALTHY after promote — run: scripts/woven-promote.sh rollback"
  printf '%s\n' "$IMG_ID" > "$SCRIPT_DIR/.woven-deployed-id"
  ok "PROMOTED live to $CANDIDATE (rollback marker: .woven-prod-rollback)"
  ;;

# ------------------------------------------------------------------ ROLLBACK
rollback)
  woven_resolve_live
  [ -f "$ROLLBACK_MARK" ] || die "no rollback marker ($ROLLBACK_MARK) — nothing to roll back to"
  TARGET="$(get_env_var "$ROLLBACK_MARK" prev_image)"
  PREV_ID="$(get_env_var "$ROLLBACK_MARK" prev_id)"
  BACKUP="$(get_env_var "$ROLLBACK_MARK" backup)"
  LIVE_ENV="$LIVE_DIR/.env"
  # resolve a usable target image: prev ref (re-pullable) or the immutable prev id
  if ! docker image inspect "$TARGET" >/dev/null 2>&1; then
    case "$TARGET" in ghcr.io/*|docker.io/*|*/*/*|*/*) : "re-pullable ref" ;; *) TARGET="$PREV_ID";; esac
    docker image inspect "$TARGET" >/dev/null 2>&1 || case "$TARGET" in ghcr.io/*|docker.io/*) : ;; *) die "rollback image unavailable locally ('$TARGET'); rebuild from git or docker load it";; esac
  fi
  log "rollback target image: $TARGET"
  cp "$LIVE_ENV" "$LIVE_ENV.bak.$TS"; chmod 600 "$LIVE_ENV.bak.$TS"
  set_env_var "$LIVE_ENV" AFFINE_IMAGE "$TARGET"
  FARGS=(); oldIFS=$IFS; IFS=,; for f in $LIVE_COMPOSE; do FARGS+=(-f "$f"); done; IFS=$oldIFS

  if [ "$DB_RESTORE" != 1 ]; then
    # TIER 1: image-only — recreate ONLY the server, do NOT re-run predeploy
    log "TIER 1 rollback (image only, no predeploy)…"
    docker compose --project-directory "$LIVE_DIR" --env-file "$LIVE_ENV" -p "$LIVE_PROJECT" "${FARGS[@]}" up -d --no-deps affine \
      || die "rollback up failed"
  else
    # TIER 2: DB+blob restore (MUST_FIX .5-3: safety backup first, NEVER rm -rf live config)
    [ -n "$BACKUP" ] && [ -f "$BACKUP/affine-db.sql.gz" ] || die "rollback --db needs a valid pre-promote backup; marker points at '$BACKUP'"
    confirm "restore db"
    log "TIER 2 rollback: snapshotting CURRENT live before destructive restore…"
    WOVEN_PG_CONTAINER="$LIVE_PG" WOVEN_SERVER_CONTAINER="$LIVE_SERVER" WOVEN_DB_USER=affine WOVEN_DB_NAME=affine \
      WOVEN_BACKUP_DIR="$BACKUP_ROOT/_pre-rollback" "$SCRIPT_DIR/woven-backup.sh"
    docker compose --project-directory "$LIVE_DIR" -p "$LIVE_PROJECT" "${FARGS[@]}" stop affine affine-migration || true
    log "restoring DB (--clean --if-exists dump, transactional)…"
    gzip -dc "$BACKUP/affine-db.sql.gz" | docker exec -i "$LIVE_PG" psql -U affine -d affine -v ON_ERROR_STOP=1 -q || die "DB restore failed"
    # blobs: ADD/overwrite into the live storage volume via helper container; extract to
    # a temp dir then cp -a — NEVER rm -rf the live volume; leave config/private.key alone.
    STOR_VOL="$(docker inspect "$LIVE_SERVER" --format '{{range .Mounts}}{{if eq .Destination "/root/.affine/storage"}}{{.Name}}{{end}}{{end}}')"
    [ -n "$STOR_VOL" ] || die "cannot resolve live storage volume"
    docker run --rm -v "$STOR_VOL":/dst -v "$BACKUP":/bak:ro --entrypoint sh "$LIVE_IMAGE_REF" -c \
      'mkdir -p /tmp/r && tar -xzf /bak/storage.tar.gz -C /tmp/r && cp -a /tmp/r/storage/. /dst/ && rm -rf /tmp/r' \
      || die "blob restore failed"
    docker compose --project-directory "$LIVE_DIR" --env-file "$LIVE_ENV" -p "$LIVE_PROJECT" "${FARGS[@]}" up -d affine \
      || die "post-restore up failed"
  fi
  woven_resolve_live
  wait_health_container "$LIVE_SERVER" || die "rollback UNHEALTHY"
  ok "ROLLED BACK live to $TARGET"
  ;;

*)
  sed -n '2,34p' "${BASH_SOURCE[0]}"; die "usage: woven-promote.sh {stage|prod|rollback} [flags]"
  ;;
esac
