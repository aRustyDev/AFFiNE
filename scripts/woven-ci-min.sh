#!/usr/bin/env bash
#
# woven-ci-min.sh — minimal pre-deploy CI gate for the Woven fork of AFFiNE.
#
# Runs the FAST tier of pre-deploy checks in order, aborting on the first failure:
#   1. typecheck        (tsc -b)
#   2. lint:ox          (oxlint --deny-warnings)
#   3. codegen-drift    (i18n + bs-docs codegen; fail if git tree changed — mirrors CI)
#   4. server AVA       (targeted specs; --forbid-only)
#   5. server e2e       (opt-in: --e2e / --full / WOVEN_CI_E2E=1 — heavy, off by default)
#
# SAFETY: server tests TRUNCATE their database. This script refuses to run unless
# DATABASE_URL points at a DISPOSABLE local stack and NOT the live self-host DB.
# See .beads/woven-cd-gate.md (bead affine-4yo.1) for the validated design.
#
# Usage:
#   scripts/woven-ci-min.sh [--e2e|--full] [AVA_GLOB ...]
# Env:
#   DATABASE_URL          (default: postgresql://affine:affine@localhost:5432/affine)
#   REDIS_SERVER_HOST     (default: localhost)
#   AFFINE_INDEXER_ENABLED(default: false — self-host parity, avoids Manticore)
#   WOVEN_CI_E2E=1        run the e2e stage
#   WOVEN_CI_FORCE=1      bypass the localhost-host assertion
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---- pretty logging -------------------------------------------------------
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[woven-ci]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[woven-ci] ✔${c_rst} $*"; }
warn() { printf '%s\n' "${c_ylw}[woven-ci] ⚠${c_rst} $*" >&2; }
die()  { printf '%s\n' "${c_red}[woven-ci] ✗${c_rst} $*" >&2; exit 1; }

# ---- args -----------------------------------------------------------------
RUN_E2E="${WOVEN_CI_E2E:-0}"
AVA_GLOBS=()
for arg in "$@"; do
  case "$arg" in
    --e2e|--full) RUN_E2E=1 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) AVA_GLOBS+=("$arg") ;;
  esac
done
# Default smoke spec if none supplied (fast, DB-backed, deterministic).
if [ "${#AVA_GLOBS[@]}" -eq 0 ]; then
  AVA_GLOBS=("src/core/quota/__tests__/*.spec.ts")
fi

# ---- toolchain: prefer node@22 (repo pins >=22.12 <23) --------------------
if ! node --version 2>/dev/null | grep -q '^v22\.'; then
  if command -v brew >/dev/null 2>&1 && brew --prefix node@22 >/dev/null 2>&1; then
    export PATH="$(brew --prefix node@22)/bin:$PATH"
  fi
fi
node --version 2>/dev/null | grep -q '^v22\.' || die "node 22.x required (got $(node --version 2>/dev/null || echo none)); brew install node@22"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
YARN=(corepack yarn)

# ---- test env defaults ----------------------------------------------------
export DATABASE_URL="${DATABASE_URL:-postgresql://affine:affine@localhost:5432/affine}"
export REDIS_SERVER_HOST="${REDIS_SERVER_HOST:-localhost}"
export AFFINE_INDEXER_ENABLED="${AFFINE_INDEXER_ENABLED:-false}"

# ---- SAFETY GUARD: never point the truncating test DB at a real database -----
# Server tests TRUNCATE. DATABASE_URL must resolve to a localhost host; anything
# else is refused unless WOVEN_CI_FORCE=1.
assert_disposable_db() {
  local url="$DATABASE_URL"
  local noproto="${url#*://}"          # user:pass@host:port/db?args
  local hostport="${noproto#*@}"       # host:port/db?args (strip creds, if any)
  hostport="${hostport%%/*}"           # host:port
  local dbhost="${hostport%%:*}"
  local dbport="${hostport##*:}"
  [ "$dbport" = "$hostport" ] && dbport=5432

  case "$dbhost" in
    localhost|127.0.0.1|::1|0.0.0.0) : ;;
    *)
      [ "${WOVEN_CI_FORCE:-0}" = "1" ] && { warn "non-local DB host '$dbhost' allowed via WOVEN_CI_FORCE"; return; }
      die "DATABASE_URL host is '$dbhost' (not localhost). Refusing — could be a live/remote DB. Set WOVEN_CI_FORCE=1 to override." ;;
  esac

  ok "DB safety: ${dbhost}:${dbport} is local — treated as the disposable dev stack."
}
assert_disposable_db

# ---- step runner ----------------------------------------------------------
STEP_NO=0
run_step() {
  local name="$1"; shift
  STEP_NO=$((STEP_NO + 1))
  log "── step ${STEP_NO}: ${name} ─────────────────────────────"
  local start=$SECONDS
  if "$@"; then
    ok "${name} ($(( SECONDS - start ))s)"
  else
    die "${name} FAILED (step ${STEP_NO})"
  fi
}

step_typecheck() { "${YARN[@]}" typecheck; }
step_lint()      { "${YARN[@]}" lint:ox; }

# Mirrors the drift checks CI actually runs (build-test.yml Lint + Typecheck jobs):
#   yarn affine @affine/i18n build   (then discard the intentionally-uncommitted
#                                     i18n-completenesses.json)
#   yarn affine bs-docs build
# then fail if the working tree changed versus the pre-codegen baseline.
I18N_COMPLETENESS="packages/frontend/i18n/src/i18n-completenesses.json"
step_codegen_drift() {
  local before after
  before="$(git status --porcelain)"
  "${YARN[@]}" affine @affine/i18n build || return 1
  # This file is regenerated on every run but intentionally NOT committed.
  git checkout -- "$I18N_COMPLETENESS" 2>/dev/null || true
  "${YARN[@]}" affine bs-docs build      || return 1
  after="$(git status --porcelain)"
  if [ "$before" != "$after" ]; then
    warn "codegen changed the working tree — generated artifacts are stale."
    warn "Regenerate and commit: 'yarn affine @affine/i18n build' / 'yarn affine bs-docs build'. New/changed vs baseline:"
    comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) >&2 || true
    return 1
  fi
}

step_ava() {
  "${YARN[@]}" affine @affine/server test "${AVA_GLOBS[@]}" --forbid-only
}

step_e2e() {
  "${YARN[@]}" affine @affine/server e2e
}

# ---- run ------------------------------------------------------------------
log "repo: ${REPO_ROOT} @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
log "DATABASE_URL host asserted disposable; AVA globs: ${AVA_GLOBS[*]}"
run_step "typecheck"      step_typecheck
run_step "lint:ox"        step_lint
run_step "codegen-drift"  step_codegen_drift
run_step "server AVA"     step_ava
if [ "$RUN_E2E" = "1" ]; then
  run_step "server e2e"   step_e2e
else
  log "server e2e: skipped (fast tier). Enable with --e2e / --full / WOVEN_CI_E2E=1."
fi

ok "ALL GATE CHECKS PASSED"
