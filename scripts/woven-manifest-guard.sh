#!/usr/bin/env bash
#
# woven-manifest-guard.sh — fail when the fork diverges from upstream on an
# upstream-owned file that scripts/woven-patch-manifest.md does not list.
#
# The manifest is bead affine-hn1's deliverable and was, until this script,
# unenforced prose. It already proved it cannot police itself: affine-hn1.1
# shipped a manifest that omitted packages/backend/server/src/seed/index.ts even
# though that same commit's audit had named the file. An unmanifested fork patch
# is silently reverted by the next "clean" upstream merge and nobody learns until
# production breaks — see the x-affine-client-kind CORS incident (affine-hn1.1).
#
# HOW OWNERSHIP IS DECIDED (no heuristics, no path allowlist):
#   changed        = git diff --name-only <baseline> <head>
#   upstream-owned = the subset that also EXISTS at <baseline>
#   fork-owned     = the rest (scripts/woven-*, new specs, .claude/**) — rebase-safe
#                    by construction, deliberately NOT tracked in the manifest.
#
# CHECKS
#   1. UNMANIFESTED — an upstream-owned file diverges with no manifest row.
#   2. STALE ROW    — a manifest row names a path absent from the tree (upstream
#                     deleted it, or it was renamed and the row was not updated).
#   Every offending path is printed, so the fix is mechanical rather than a
#   re-audit. Rows for files that no longer diverge are reported as a WARNING
#   only — harmless staleness, not a reason to block a PR.
#
# EXIT CODES (contract — see scripts/woven-manifest-guard.test.sh)
#   0  clean
#   1  policy violation
#   2  usage or environment error (unresolvable baseline, missing manifest)
#
# Usage:
#   scripts/woven-manifest-guard.sh [--base REF] [--head REF] [--manifest PATH]
#
# The baseline defaults to UPSTREAM_COMMIT in scripts/woven-upstream-baseline.
# It must be RESOLVABLE: in CI use actions/checkout with fetch-depth: 0, since a
# shallow clone will not contain the merge's upstream parent.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[manifest-guard]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[manifest-guard] ✔${c_rst} $*"; }
warn() { printf '%s\n' "${c_ylw}[manifest-guard] ⚠${c_rst} $*" >&2; }
err()  { printf '%s\n' "${c_red}[manifest-guard] ✗${c_rst} $*" >&2; }
die()  { err "$*"; exit 2; }

# ---- args -----------------------------------------------------------------
BASE=""
HEAD_REF="HEAD"
HEAD_EXPLICIT=0
MANIFEST="$REPO_ROOT/scripts/woven-patch-manifest.md"
BASELINE_FILE="$REPO_ROOT/scripts/woven-upstream-baseline"

while [ $# -gt 0 ]; do
  case "$1" in
    --base)     [ $# -ge 2 ] || die "--base needs a ref";      BASE="$2";     shift 2 ;;
    --head)     [ $# -ge 2 ] || die "--head needs a ref";      HEAD_REF="$2"; HEAD_EXPLICIT=1; shift 2 ;;
    --manifest) [ $# -ge 2 ] || die "--manifest needs a path"; MANIFEST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,37p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
done

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

# ---- resolve the upstream baseline ----------------------------------------
if [ -z "$BASE" ]; then
  [ -f "$BASELINE_FILE" ] || die "baseline file not found: $BASELINE_FILE"
  BASE="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$BASELINE_FILE" | head -1)"
  [ -n "$BASE" ] || die "UPSTREAM_COMMIT missing from $BASELINE_FILE"
fi

BASE_SHA="$(git rev-parse --verify --quiet "${BASE}^{commit}" || true)"
if [ -z "$BASE_SHA" ]; then
  err "cannot resolve the upstream baseline '$BASE' in this repository."
  err "A shallow checkout will not contain it — use actions/checkout with 'fetch-depth: 0',"
  err "or update UPSTREAM_COMMIT in $BASELINE_FILE."
  exit 2
fi
HEAD_SHA="$(git rev-parse --verify --quiet "${HEAD_REF}^{commit}" || true)"
[ -n "$HEAD_SHA" ] || die "cannot resolve head ref '$HEAD_REF'"

# Fold in uncommitted work unless a --head was named. Run before committing, a
# guard that only ever diffs HEAD reports "clean" on the very change you are
# about to push — the exact miss this file exists to prevent. In CI the tree is
# clean, so this changes nothing there; pass --head explicitly to force
# committed-only semantics.
WORKTREE=0
if [ "$HEAD_EXPLICIT" -eq 0 ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  WORKTREE=1
fi

log "baseline $(git rev-parse --short "$BASE_SHA")  head $(git rev-parse --short "$HEAD_SHA")"
[ "$WORKTREE" -eq 1 ] && log "including UNCOMMITTED working-tree changes (pass --head HEAD for committed only)"
log "manifest ${MANIFEST#"$REPO_ROOT/"}"

# ---- parse the manifest ----------------------------------------------------
# Only the "## Diverged upstream-owned files" table counts. The category legend
# above it and the measured-justification table below it are also pipe tables;
# scoping to the section (and requiring a backticked path in COLUMN 1) keeps
# rows like `cloudflare.com` from being mistaken for tracked files.
manifest_rows() {
  awk '
    /^##[[:space:]]+Diverged upstream-owned files/ { insec = 1; next }
    insec && /^#+[[:space:]]/                      { insec = 0 }
    insec && /^[[:space:]]*\|/ {
      n = split($0, f, "|")
      if (n < 2) next
      if (match(f[2], /`[^`]+`/)) print substr(f[2], RSTART + 1, RLENGTH - 2)
    }
  ' "$MANIFEST"
}

MANIFESTED="$(manifest_rows | sed 's#^\./##' | sed '/^$/d' | sort -u)"
[ -n "$MANIFESTED" ] || warn "the manifest table lists no files — is the '## Diverged upstream-owned files' heading intact?"

# ---- classify the divergence ----------------------------------------------
# In worktree mode diff the baseline against the working tree. Untracked files
# are ignored on purpose: absent from the baseline, they are fork-owned by
# definition and so can never be an unmanifested upstream-owned change.
if [ "$WORKTREE" -eq 1 ]; then
  CHANGED="$(git diff --name-only "$BASE_SHA" | sed '/^$/d')"
else
  CHANGED="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" | sed '/^$/d')"
fi
UPSTREAM_OWNED=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Upstream owns it iff it existed at the baseline. Everything else is a
  # fork-owned addition and is rebase-safe by construction.
  if git cat-file -e "${BASE_SHA}:${p}" 2>/dev/null; then
    UPSTREAM_OWNED="${UPSTREAM_OWNED}${p}"$'\n'
  fi
done <<< "$CHANGED"
UPSTREAM_OWNED="$(printf '%s' "$UPSTREAM_OWNED" | sed '/^$/d' | sort -u)"

n_changed=$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')
n_upstream=$(printf '%s\n' "$UPSTREAM_OWNED" | sed '/^$/d' | wc -l | tr -d ' ')
n_rows=$(printf '%s\n' "$MANIFESTED" | sed '/^$/d' | wc -l | tr -d ' ')
log "${n_changed} changed vs baseline · ${n_upstream} upstream-owned · ${n_rows} manifest row(s)"

# ---- check 1: unmanifested upstream-owned divergence -----------------------
UNMANIFESTED="$(comm -23 <(printf '%s\n' "$UPSTREAM_OWNED" | sed '/^$/d') \
                         <(printf '%s\n' "$MANIFESTED"     | sed '/^$/d'))"

# ---- check 2: rows whose path is gone from the tree ------------------------
STALE=""
UNDIVERGED=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Resolve the row against whatever tree we are judging: the filesystem in
  # worktree mode, the committed tree otherwise.
  if [ "$WORKTREE" -eq 1 ]; then
    path_present() { [ -e "$REPO_ROOT/$1" ]; }
  else
    path_present() { git cat-file -e "${HEAD_SHA}:${1}" 2>/dev/null; }
  fi
  if ! path_present "$p"; then
    STALE="${STALE}${p}"$'\n'
  elif ! printf '%s\n' "$UPSTREAM_OWNED" | grep -qxF -- "$p"; then
    UNDIVERGED="${UNDIVERGED}${p}"$'\n'
  fi
done <<< "$MANIFESTED"

# ---- report ----------------------------------------------------------------
rc=0

if [ -n "$UNMANIFESTED" ]; then
  rc=1
  err "UNMANIFESTED upstream-owned divergence — add a row to scripts/woven-patch-manifest.md:"
  while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$UNMANIFESTED"
  err ""
  err "  Each row needs: | \`path\` | **ADDITIVE** or **FORK-LOCAL CORE PATCH** | why | delete when |"
  err "  ADDITIVE = new fork-owned surface, no upstream behavior change."
  err "  FORK-LOCAL CORE PATCH = changes upstream behavior (auth/quota/permission/limits). NEVER upstream."
  err "  If the divergence was unintentional, revert it instead:"
  err "    git diff $(git rev-parse --short "$BASE_SHA") -- <path>"
fi

if [ -n "$STALE" ]; then
  rc=1
  err "STALE manifest row(s) — the path no longer exists in the tree; upstream probably deleted or renamed it:"
  while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$STALE"
  err "  Drop the row, or repoint it at the new path."
fi

if [ -n "$UNDIVERGED" ]; then
  warn "manifest row(s) for files that no longer diverge from the baseline (not fatal — consider dropping the row):"
  while IFS= read -r p; do [ -n "$p" ] && warn "    $p"; done <<< "$UNDIVERGED"
fi

if [ "$rc" -eq 0 ]; then
  ok "every upstream-owned divergence is manifested, and every row resolves."
else
  err "manifest guard FAILED — see scripts/woven-patch-manifest.md (bead affine-hn1)."
fi
exit "$rc"
