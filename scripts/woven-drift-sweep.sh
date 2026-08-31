#!/usr/bin/env bash
#
# woven-drift-sweep.sh — list open/in_progress beads whose text cites a file the
# fork has changed, so a human can check them for plan drift after a merge.
#
# affine-3os: "After every upstream merge and every merged PR, run a plan-drift
# sweep over open tasks in affected areas." For the v0.27.4 merge that sweep did
# not run; a hand audit five days later found affine-yiz stale by 117 commits
# with its halt analysis invalidated, and affine-4aj half-fixed with no note.
# Neither needed judgment to spot — both were mechanically derivable from the
# diff, which is what this script derives. The rule existed; the trigger did not.
#
# ADVISORY, NOT A GATE. It always exits 0 on success: it produces candidates for
# a human to read, and there is no correct set to fail against. It is also NOT
# wired into GitHub CI — bd talks to a shared Dolt server that runners cannot
# reach. It belongs to the merge-time checklist in scripts/woven-patch-manifest.md.
#
# MATCHING. A bead is a candidate if its title / description / acceptance
# criteria / notes mention a changed file by full path, or by basename when that
# basename is distinctive. Generic basenames (index.ts, package.json, ...) are
# skipped: `packages/backend/server/src/seed/index.ts` otherwise drags in every
# bead that ever wrote "index.ts", and a noisy sweep stops being run.
#
# EXIT CODES
#   0  swept (candidates or none)
#   2  usage or environment error
#
# Usage:
#   scripts/woven-drift-sweep.sh [--base REF] [--head REF] [--beads FILE]
#
#   --base   defaults to UPSTREAM_COMMIT in scripts/woven-upstream-baseline, so
#            the default sweep covers all fork divergence from upstream.
#            For the narrower "what did this merge move" question, pass the
#            merge's own parents:  --base <merge>^1 --head <merge>
#   --beads  a bd JSON corpus; defaults to a live `bd list` query.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_bld=$'\033[1m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[drift-sweep]${c_rst} $*"; }
die()  { printf '%s\n' "[drift-sweep] ✗ $*" >&2; exit 2; }

# Basenames too generic to match on. Full-path citations still match these.
GENERIC='^(index|main|mod|lib|types|utils|config|def|constants|helpers|README|CHANGELOG|Dockerfile|package|tsconfig|package-lock|yarn)\.'

BASE=""
HEAD_REF="HEAD"
BEADS=""
BASELINE_FILE="$REPO_ROOT/scripts/woven-upstream-baseline"

while [ $# -gt 0 ]; do
  case "$1" in
    --base)    [ $# -ge 2 ] || die "--base needs a ref";   BASE="$2";     shift 2 ;;
    --head)    [ $# -ge 2 ] || die "--head needs a ref";   HEAD_REF="$2"; shift 2 ;;
    --beads)   [ $# -ge 2 ] || die "--beads needs a path"; BEADS="$2";    shift 2 ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"

# Some jq builds emit CRLF, leaving a trailing \r on every id printed. That \r
# garbles the report and breaks `select(.id == $id)` lookups. Strip it at source.
jqr() { jq -r "$@" | tr -d '\r'; }

# ---- resolve the diff range ------------------------------------------------
if [ -z "$BASE" ]; then
  [ -f "$BASELINE_FILE" ] || die "baseline file not found: $BASELINE_FILE"
  BASE="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$BASELINE_FILE" | head -1)"
  [ -n "$BASE" ] || die "UPSTREAM_COMMIT missing from $BASELINE_FILE"
fi
BASE_SHA="$(git rev-parse --verify --quiet "${BASE}^{commit}" || true)"
[ -n "$BASE_SHA" ] || die "cannot resolve base ref '$BASE' (shallow clone? see $BASELINE_FILE)"
HEAD_SHA="$(git rev-parse --verify --quiet "${HEAD_REF}^{commit}" || true)"
[ -n "$HEAD_SHA" ] || die "cannot resolve head ref '$HEAD_REF'"

# ---- bead corpus -----------------------------------------------------------
CORPUS="$(mktemp)"
trap 'rm -f "$CORPUS"' EXIT
if [ -n "$BEADS" ]; then
  [ -f "$BEADS" ] || die "bead corpus not found: $BEADS"
  cp "$BEADS" "$CORPUS"
else
  bd list --status open,in_progress --json >"$CORPUS" 2>/dev/null \
    || die "bd list failed — is the Dolt server up? (bd dolt start)"
fi
jq -e 'type == "array"' "$CORPUS" >/dev/null 2>&1 || die "bead corpus is not a JSON array: ${BEADS:-bd list}"

n_beads="$(jqr 'length' "$CORPUS")"
CHANGED="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" | sed '/^$/d')"
n_changed="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')"

log "range $(git rev-parse --short "$BASE_SHA")..$(git rev-parse --short "$HEAD_SHA") · ${n_changed} changed file(s) · ${n_beads} open/in_progress bead(s)"
echo

# ---- match ------------------------------------------------------------------
HITS="$(mktemp)"; trap 'rm -f "$CORPUS" "$HITS"' EXIT
while IFS= read -r p; do
  [ -n "$p" ] || continue
  b="$(basename "$p")"
  # Fold the generic basename into the full path so jq only ever gets one needle
  # when the basename is not distinctive enough to search on its own.
  if printf '%s' "$b" | grep -qE "$GENERIC"; then b="$p"; fi
  ids="$(jqr --arg p "$p" --arg b "$b" '
      .[]
      | select((((.title//"") + " " + (.description//"") + " "
                 + (.acceptance_criteria//"") + " " + (.notes//"")))
               | (contains($p) or contains($b)))
      | .id' "$CORPUS" | sort -u)"
  [ -n "$ids" ] || continue
  while IFS= read -r id; do
    [ -n "$id" ] && printf '%s\t%s\n' "$id" "$p" >>"$HITS"
  done <<< "$ids"
done <<< "$CHANGED"

# ---- report -----------------------------------------------------------------
if [ ! -s "$HITS" ]; then
  printf '%s\n' "${c_grn}No open bead cites a changed file — nothing to sweep.${c_rst}"
  exit 0
fi

printf '%s\n' "${c_bld}Drift candidates — beads citing a file this range changed:${c_rst}"
echo
cut -f1 "$HITS" | sort -u | while IFS= read -r id; do
  title="$(jqr --arg id "$id" '.[] | select(.id==$id) | .title' "$CORPUS" | head -1)"
  status="$(jqr --arg id "$id" '.[] | select(.id==$id) | .status' "$CORPUS" | head -1)"
  printf '  %s%s%s  [%s]  %s\n' "$c_bld" "$id" "$c_rst" "$status" "${title:0:88}"
  # Plain awk on the id field: grep -P is not portable, and an id like
  # affine-hn1.2 is a regex if fed to grep.
  awk -F'\t' -v id="$id" '$1 == id { print $2 }' "$HITS" | sort -u | sed 's/^/        /'
done

cat <<'CLASSES'

Read each candidate against the diff and look for the three drift classes the
2026-08-29 audit actually found (affine-hn1.3):

  (a) SATISFIED   — an open bead whose acceptance criteria the merge already
                    meets. Close it with the evidence.
                    e.g. affine-hn1.1 was fully satisfied and still open.
  (b) INVALIDATED  — an in_progress bead whose analysis the merge broke: a stale
                    image or SHA, a path that moved, a new migration its safety
                    argument never accounted for. Reset it to open and say in the
                    notes that the plan is invalid, not merely paused.
                    e.g. affine-yiz: image 117 commits stale, new CONTRACT migration.
  (c) INCIDENTAL   — a bead whose fix landed as a side effect of some other
                    commit, with nothing written on the bead. Record what was
                    fixed and what is still open.
                    e.g. affine-4aj: half-fixed by 4384cd820c, unnoted.

Also run `bd lint` and read the task/feature/bug rows only — the epic warnings
are noise by design (affine-3os keeps epics thin until they enter the horizon).
CLASSES
exit 0
