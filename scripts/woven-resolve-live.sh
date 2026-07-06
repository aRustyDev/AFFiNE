# woven-resolve-live.sh — sourced helper. Resolve the live AFFiNE deployment BY
# IDENTITY (the container publishing host :3010), never by an assumed name, and
# DIE rather than guess. Robust to compose-project renames (e.g. the old
# standalone `affine` project -> the `woven-local` platform stack).
#
# Usage:  . "$(dirname "$0")/woven-resolve-live.sh"; woven_resolve_live
# Sets:   LIVE_SERVER LIVE_PROJECT LIVE_COMPOSE LIVE_DIR LIVE_PG
#         LIVE_IMAGE_ID (immutable running binary) LIVE_IMAGE_REF (digest-pinned ref)
# Override via env: WOVEN_LIVE_SERVER, WOVEN_LIVE_PG, WOVEN_LIVE_PORT (default 3010).

_wrl() { printf '%s\n' "[woven-resolve] $*" >&2; }

woven_resolve_live() {
  local port="${WOVEN_LIVE_PORT:-3010}"
  LIVE_SERVER="${WOVEN_LIVE_SERVER:-}"
  if [ -z "$LIVE_SERVER" ]; then
    LIVE_SERVER="$(docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -1)"
  fi
  [ -n "$LIVE_SERVER" ] || { _wrl "cannot find live AFFiNE server (nothing publishes :${port}); set WOVEN_LIVE_SERVER"; return 1; }
  docker inspect "$LIVE_SERVER" >/dev/null 2>&1 || { _wrl "live server '$LIVE_SERVER' not found"; return 1; }

  LIVE_PROJECT="$(docker inspect "$LIVE_SERVER" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)"
  LIVE_DIR="$(docker inspect "$LIVE_SERVER"     --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)"
  LIVE_COMPOSE="$(docker inspect "$LIVE_SERVER" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)"
  LIVE_IMAGE_ID="$(docker inspect "$LIVE_SERVER"  --format '{{.Image}}' 2>/dev/null)"
  LIVE_IMAGE_REF="$(docker inspect "$LIVE_SERVER" --format '{{.Config.Image}}' 2>/dev/null)"
  [ -n "${LIVE_PROJECT}${LIVE_IMAGE_ID}" ] || { _wrl "live server '$LIVE_SERVER' has no compose labels/image id — unmanaged?"; return 1; }

  LIVE_PG="${WOVEN_LIVE_PG:-}"
  if [ -z "$LIVE_PG" ] && [ -n "$LIVE_PROJECT" ]; then
    LIVE_PG="$(docker ps \
      --filter "label=com.docker.compose.project=$LIVE_PROJECT" \
      --filter "label=com.docker.compose.service=postgres" \
      --format '{{.Names}}' 2>/dev/null | head -1)"
  fi
  [ -n "$LIVE_PG" ] || { _wrl "cannot find postgres container in project '$LIVE_PROJECT'; set WOVEN_LIVE_PG"; return 1; }
  return 0
}

# Resolve the app DB user/name from the live server's DATABASE_URL (POSTGRES_DB is
# empty on the shared multi-tenant postgres). Sets LIVE_DB_USER / LIVE_DB_NAME.
woven_resolve_db_identity() { # <server_container>
  local url
  url="$(docker exec "$1" printenv DATABASE_URL 2>/dev/null || true)"
  LIVE_DB_USER="${WOVEN_DB_USER:-$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^:]+):.*#\1#')}"
  LIVE_DB_NAME="${WOVEN_DB_NAME:-$(printf '%s' "$url" | sed -E 's#.*/([^/?]+)([?].*)?$#\1#')}"
  [ -n "$LIVE_DB_USER" ] && [ -n "$LIVE_DB_NAME" ] || return 1
  return 0
}
