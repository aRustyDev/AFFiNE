#!/usr/bin/env bash
#
# woven-build-image.sh — build a promotable LOCAL fork image from source.
#
# Prints the resulting image tag on STDOUT (logs go to stderr) so callers can:
#   CANDIDATE="$(scripts/woven-build-image.sh)"
#
# The fork cannot push to ghcr.io/toeverything, so images are local-only:
#   woven/affine:<git-short-sha>   (immutable; promote pins this, never a moving tag)
#
# MUST_FIX .5-2: a DIRTY tree makes the sha tag lie about the image contents, so a
# dirty build HARD-FAILS unless WOVEN_ALLOW_DIRTY=1 (which yields a *-dirty tag that
# woven-promote.sh refuses to stage/promote).
#
# Usage:   scripts/woven-build-image.sh [--print]
# Env:
#   WOVEN_IMAGE        passthrough: if set, validate it exists and echo it (skips build;
#                      lets promote orchestration be validated with the upstream image)
#   BUILD_TYPE         frontend build type (default: stable)
#   WOVEN_ALLOW_DIRTY=1  build from a dirty tree -> woven/affine:<sha>-dirty (non-promotable)
#
set -euo pipefail
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[woven-build]${c_rst} $*" >&2; }
ok()   { printf '%s\n' "${c_grn}[woven-build] ✔${c_rst} $*" >&2; }
die()  { printf '%s\n' "${c_red}[woven-build] ✗${c_rst} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRINT_ONLY=0; [ "${1:-}" = "--print" ] && PRINT_ONLY=1
BUILD_TYPE="${BUILD_TYPE:-stable}"
command -v docker >/dev/null 2>&1 || die "docker not found"

# passthrough: use an already-present image (e.g. the upstream one) as the candidate
if [ -n "${WOVEN_IMAGE:-}" ]; then
  docker image inspect "$WOVEN_IMAGE" >/dev/null 2>&1 || die "WOVEN_IMAGE '$WOVEN_IMAGE' not present locally"
  log "passthrough image: $WOVEN_IMAGE"
  printf '%s\n' "$WOVEN_IMAGE"; exit 0
fi

git -C "$REPO_ROOT" rev-parse --short HEAD >/dev/null 2>&1 || die "not a git repo: $REPO_ROOT"
SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
DIRTY=0
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  if [ "${WOVEN_ALLOW_DIRTY:-0}" = 1 ]; then DIRTY=1; SHA="${SHA}-dirty"
  else die "working tree dirty — commit or stash before building a promotable image (WOVEN_ALLOW_DIRTY=1 builds a NON-promotable woven/affine:${SHA}-dirty)"; fi
fi
TAG="woven/affine:$SHA"

if [ "$PRINT_ONLY" = 1 ]; then printf '%s\n' "$TAG"; exit 0; fi

log "building $TAG (BUILD_TYPE=$BUILD_TYPE) from source — this is SLOW (10-30 min)…"
[ "$DIRTY" = 1 ] && log "WARNING: dirty build; $TAG is NOT promotable (woven-promote.sh refuses *-dirty)"
# Use the woven dockerignore for a lean context without disturbing any repo .dockerignore.
DI="$REPO_ROOT/.dockerignore.woven.$$"; cp "$REPO_ROOT/scripts/woven.dockerignore" "$DI"
trap 'rm -f "$DI"' EXIT
DOCKER_BUILDKIT=1 docker build \
  --platform linux/arm64 \
  -f "$REPO_ROOT/scripts/woven.Dockerfile" \
  --build-arg BUILD_TYPE="$BUILD_TYPE" \
  --build-arg APP_VERSION="$SHA" \
  -t "$TAG" \
  "$REPO_ROOT" >&2

arch="$(docker image inspect "$TAG" --format '{{.Architecture}}' 2>/dev/null || true)"
[ "$arch" = arm64 ] || die "built image arch is '$arch', expected arm64"
ok "built $TAG (arm64)"
printf '%s\n' "$TAG"
