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
#   1. UNMANIFESTED    — an upstream-owned file diverges with no manifest row.
#   2. STALE ROW       — a manifest row names a path absent from the tree
#                         (upstream deleted it, or it was renamed and the row
#                         was not updated).
#   3. UNPARSEABLE ROW — an in-section table row that is not the header, not
#                         the separator, and not a well-formed
#                         `path` | category row (e.g. a missing backtick).
#                         Never silently dropped.
#   4. BAD CATEGORY    — a row's category, once markdown emphasis is
#                         stripped, is not exactly ADDITIVE or FORK-LOCAL CORE
#                         PATCH. Never guessed as ADDITIVE.
#   Every offending path is printed, so the fix is mechanical rather than a
#   re-audit. Rows for files that no longer diverge are reported as a WARNING
#   only — harmless staleness, not a reason to block a PR.
#
# EXIT CODES (contract — see scripts/woven-manifest-guard.test.sh)
#   0  clean
#   1  policy violation
#   2  usage or environment error — unresolvable baseline, missing manifest,
#      an unparseable manifest row, an unrecognised category, or (under
#      --outbound) a manifest table with no rows at all.
#
# Usage:
#   scripts/woven-manifest-guard.sh [--base REF] [--head REF] [--manifest PATH]
#   scripts/woven-manifest-guard.sh --outbound [--base REF] [--head REF] [--manifest PATH]
#   scripts/woven-manifest-guard.sh --dump-rows [--manifest PATH]
#
# INBOUND (default): fail when an upstream-owned file diverges with no manifest
# row — don't silently lose a fork patch to the next upstream merge.
# OUTBOUND (--outbound): fail when the change set touches a file whose manifest
# row says FORK-LOCAL CORE PATCH — don't leak a fork patch to upstream.
# --dump-rows is a debugging aid, not a check: it prints every row the parser
# and classifier saw — `path<TAB>category` for a row that parsed (the category
# it was actually bucketed as, not just the raw manifest text — an inverted
# ADDITIVE/FORK-LOCAL CORE PATCH classification would show up here), or
# `!UNPARSED<TAB><raw line>` for one that didn't parse — then exits 0 without
# running any of the four checks above. It answers "what did the parser and
# classifier actually see?", which is exactly the question you want answered
# when a row gets rejected, or when you want to confirm a path is paired with
# the category you think it is before trusting that pairing.
#
# The baseline defaults to UPSTREAM_COMMIT in scripts/woven-upstream-baseline.
# It must be RESOLVABLE: in CI use actions/checkout with fetch-depth: 0, since a
# shallow clone will not contain the merge's upstream parent.
#
set -uo pipefail

# sort -u below dedupes by COLLATION, not by byte value. Under a UTF-8 locale
# two byte-distinct paths can compare collation-equal and silently collapse —
# if the dropped line were the fork-local path, outbound would fail open. This
# makes the sorted-order invariant `comm` relies on explicit rather than
# incidental to whatever locale happens to be set.
export LC_ALL=C

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
OUTBOUND=0
DUMP_ROWS=0
MANIFEST="$REPO_ROOT/scripts/woven-patch-manifest.md"
BASELINE_FILE="$REPO_ROOT/scripts/woven-upstream-baseline"

while [ $# -gt 0 ]; do
  case "$1" in
    --base)       [ $# -ge 2 ] || die "--base needs a ref";      BASE="$2";     shift 2 ;;
    --head)       [ $# -ge 2 ] || die "--head needs a ref";      HEAD_REF="$2"; HEAD_EXPLICIT=1; shift 2 ;;
    --manifest)   [ $# -ge 2 ] || die "--manifest needs a path"; MANIFEST="$2"; shift 2 ;;
    --outbound)   OUTBOUND=1; shift ;;
    --dump-rows)  DUMP_ROWS=1; shift ;;
    -h|--help)    awk 'NR>1 && !/^#/{exit} NR>1' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            die "unknown argument: $1" ;;
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
# rows like `cloudflare.com` from being mistaken for tracked files. A pipe row
# is the table's header until the separator (the `| --- | --- |` row) is seen —
# tracked structurally so renaming the header text (e.g. "File" -> "Path") does
# not turn a cosmetic edit into an UNPARSED failure. After the separator, an
# in-section row that is not a well-formed `path` | category row is emitted on
# a "!UNPARSED" marker line instead of being silently dropped — see the
# UNPARSED check below, which turns that into exit 2.
manifest_rows() {
  awk '
    /^##[[:space:]]+Diverged upstream-owned files/ { insec = 1; sep_seen = 0; next }
    insec && /^#+[[:space:]]/                      { insec = 0 }
    insec && /^[[:space:]]*\|/ {
      if ($0 ~ /^[[:space:]]*\|[-:|[:space:]]*$/) { sep_seen = 1; next }  # separator row
      if (!sep_seen) next                                                # header row(s) above it
      n = split($0, f, "|")
      if (n >= 3 && match(f[2], /`[^`]+`/)) {
        path = substr(f[2], RSTART + 1, RLENGTH - 2)
        cat = f[3]
        gsub(/[*_`]/, "", cat)              # drop markdown emphasis (**, __, `)
        sub(/^[[:space:]]+/, "", cat)
        sub(/[[:space:]]+$/, "", cat)
        print path "\t" cat
        next
      }
      print "!UNPARSED\t" $0
    }
  ' "$MANIFEST"
}

# Called once; --dump-rows, the UNPARSED check, MANIFESTED and the category
# classification below all read from this same value so none of them can
# drift against each other (manifest_rows previously ran twice, normalised
# differently each time).
ROWS="$(manifest_rows | sed 's#^\./##')"
UNPARSED_RAW="$(printf '%s\n' "$ROWS" | grep '^!UNPARSED')"
UNPARSED="$(printf '%s\n' "$UNPARSED_RAW" | cut -f2-)"

# ---- classify the manifest rows by category --------------------------------
# Column 2 is the FORK-LOCAL CORE PATCH / ADDITIVE distinction from affine-cm9.
# An unrecognised value exits 2 in BOTH directions: it is a broken manifest, not
# a policy violation, and guessing "probably additive" is how a leak ships.
#
# CLASSIFIED is built here and is exactly what --dump-rows prints — see below
# for why FORKLOCAL is derived from it rather than built alongside it.
BADCAT=""
CLASSIFIED=""
while IFS=$'\t' read -r p c; do
  [ -n "$p" ] || continue
  case "$c" in
    "FORK-LOCAL CORE PATCH")
      CLASSIFIED="${CLASSIFIED}${p}"$'\t'"FORK-LOCAL CORE PATCH"$'\n'
      ;;
    "ADDITIVE")
      CLASSIFIED="${CLASSIFIED}${p}"$'\t'"ADDITIVE"$'\n'
      ;;
    *)
      BADCAT="${BADCAT}${p}  [category: ${c:-<empty>}]"$'\n'
      CLASSIFIED="${CLASSIFIED}${p}"$'\t'"!BADCAT(${c:-<empty>})"$'\n'
      ;;
  esac
done <<< "$(printf '%s\n' "$ROWS" | grep -v '^!UNPARSED')"

# FORKLOCAL is DERIVED from CLASSIFIED — the same value --dump-rows prints — so
# the list this guard acts on is the list an operator can inspect. Building the
# two in parallel would let them drift, and a fixture over the dump could not
# see it. Exact field match, never a substring: a marker line must not be
# mistaken for a classification.
FORKLOCAL="$(printf '%s' "$CLASSIFIED" | awk -F'\t' '$2=="FORK-LOCAL CORE PATCH"{print $1}' | sort -u)"

# ---- --dump-rows: debugging aid, not a check -------------------------------
# Prints what the parser AND the classifier saw — `path<TAB>category` per row,
# `!UNPARSED<TAB><raw line>` for one that didn't parse — then exits before any
# of the four checks below can fail the guard. Use it to see exactly what
# a rejected row looked like, or to confirm a path is paired with the category
# you think it is before trusting that pairing.
if [ "$DUMP_ROWS" -eq 1 ]; then
  printf '%s\n' "$UNPARSED_RAW" | sed '/^$/d'
  printf '%s' "$CLASSIFIED"
  exit 0
fi

# ---- check: in-section rows that should have parsed and did not -----------
# A row missing its backticked path, or otherwise malformed, used to vanish
# silently (n < 3 -> skipped) — landing in neither MANIFESTED nor FORKLOCAL.
# Inbound still caught the file as UNMANIFESTED, but outbound trusts absence
# from FORKLOCAL as "safe to send upstream", so a silently dropped row would
# fail OPEN there. Refuse to guess; name it and exit 2.
if [ -n "$UNPARSED" ]; then
  err "manifest row(s) in $MANIFEST that could not be parsed — refusing to guess:"
  while IFS= read -r l; do [ -n "$l" ] && err "    $l"; done <<< "$UNPARSED"
  err "  Each row needs: | \`path\` | **ADDITIVE** or **FORK-LOCAL CORE PATCH** | why | delete when |"
  exit 2
fi

MANIFESTED="$(printf '%s\n' "$ROWS" | grep -v '^!UNPARSED' | cut -f1 | sed '/^$/d' | sort -u)"
if [ -z "$MANIFESTED" ]; then
  if [ "$OUTBOUND" -eq 1 ]; then
    die "the manifest table in $MANIFEST lists no files — refusing to treat an empty manifest as \"nothing to leak\" under --outbound. Is the '## Diverged upstream-owned files' heading intact?"
  fi
  warn "the manifest table lists no files — is the '## Diverged upstream-owned files' heading intact?"
fi

if [ -n "$BADCAT" ]; then
  err "manifest row(s) in $MANIFEST with an unrecognised category — refusing to guess:"
  while IFS= read -r l; do [ -n "$l" ] && err "    $l"; done <<< "$BADCAT"
  err ""
  err "  Each row needs: | \`path\` | **ADDITIVE** or **FORK-LOCAL CORE PATCH** | why | delete when |"
  err "  Column 2 must read ADDITIVE or FORK-LOCAL CORE PATCH once markdown emphasis (*, _, \`) is stripped."
  exit 2
fi

# ---- classify the divergence ----------------------------------------------
# In worktree mode diff the baseline against the working tree. Untracked files
# are ignored on purpose: absent from the baseline, they are fork-owned by
# definition and so can never be an unmanifested upstream-owned change.
#
# --no-renames: rename detection is ON by default and --name-only then reports
# only the DESTINATION path. Renaming a FORK-LOCAL CORE PATCH file to a new
# name with unchanged content would make the manifested (source) path vanish
# from this list entirely, so both the unmanifested check and the outbound
# leak check would see nothing — a stale row is how that gets caught instead
# (see STALE below). -c core.quotePath=false: the default quotePath=true
# C-quotes non-ASCII paths (e.g. `pkg/café.ts` -> `"pkg/caf\303\251.ts"`), and
# that quoted form matches nothing in the manifest or in git cat-file lookups
# — a silent drop from both UPSTREAM_OWNED and FORKLOCAL alike.
if [ "$WORKTREE" -eq 1 ]; then
  CHANGED="$(git -c core.quotePath=false diff --no-renames --name-only "$BASE_SHA" | sed '/^$/d')"
else
  CHANGED="$(git -c core.quotePath=false diff --no-renames --name-only "$BASE_SHA" "$HEAD_SHA" | sed '/^$/d')"
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
comm_rc=$?
[ "$comm_rc" -eq 0 ] || die "comm failed while computing UNMANIFESTED (exit $comm_rc) — an environment error, not a policy determination; refusing to report a possibly-wrong result."

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

# ---- OUTBOUND mode: don't leak a fork patch to upstream --------------------
# Asks an ADDITIONAL question to the inbound one, over the same inputs: not just
# "is this divergence declared?" but "is this change set carrying something
# marked NEVER-upstream?". Runs after BOTH inbound checks — UNMANIFESTED and
# STALE — rather than just the first: outbound requires the branch to be
# INBOUND-CLEAN, not merely unmanifested-clean. A stale row's category no
# longer describes this tree either — for example a rename (CHANGED above is
# taken with --no-renames precisely so a rename cannot hide the old path from
# this diff) leaves the manifested path absent from the tree, and the row's
# classification becomes unverifiable — the same "absence is ambiguous" shape
# the unmanifested check exists to close on the other side.
#
# FORKLOCAL is derived from the manifest, so a row the parser cannot read
# silently leaves the set, and an empty set looks exactly like "nothing to
# leak". An unreadable or stale row makes gating here fail closed by
# construction rather than by having been anticipated. It also means the
# checks can never disagree: a branch cannot be "safe to send upstream" while
# carrying a divergence the fork has not declared, or a row whose meaning this
# tree can no longer confirm.
if [ "$OUTBOUND" -eq 1 ]; then
  if [ -n "$UNMANIFESTED" ] || [ -n "$STALE" ]; then
    if [ -n "$UNMANIFESTED" ]; then
      err "cannot judge this change set: upstream-owned file(s) with no manifest row:"
      while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$UNMANIFESTED"
      err ""
      err "  An undeclared divergence has no category, so it cannot be cleared for"
      err "  upstream. Add a row to ${MANIFEST#"$REPO_ROOT/"} — or revert the change."
    fi
    if [ -n "$STALE" ]; then
      err "cannot judge this change set: manifest row(s) whose path no longer exists in the tree:"
      while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$STALE"
      err ""
      err "  A stale row's category no longer describes this tree — the file may have"
      err "  been renamed (a rename would otherwise hide the old path from this diff)"
      err "  or deleted. Update or drop the row in ${MANIFEST#"$REPO_ROOT/"} before this"
      err "  branch can be judged safe for upstream."
    fi
    exit 1
  fi
  LEAKED="$(comm -12 <(printf '%s\n' "$CHANGED"   | sed '/^$/d' | sort -u) \
                     <(printf '%s\n' "$FORKLOCAL" | sed '/^$/d' | sort -u))"
  comm_rc=$?
  [ "$comm_rc" -eq 0 ] || die "comm failed while computing LEAKED (exit $comm_rc) — an environment error, not a policy determination; refusing to report a possibly-wrong result."
  if [ -n "$LEAKED" ]; then
    err "FORK-LOCAL CORE PATCH on an upstream-directed change set:"
    while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$LEAKED"
    err ""
    err "  These files change upstream behaviour and must NEVER reach upstream (affine-cm9)."
    err "  This branch is not safe to send to the upstream repository."
    err "  Start an upstream-bound branch from the upstream baseline instead:"
    err "    scripts/woven-upstream-branch.sh <name> <path>..."
    err "  There is no override. If a category is genuinely wrong, change the"
    err "  manifest row in a reviewed commit."
    exit 1
  fi
  ok "no FORK-LOCAL CORE PATCH in this change set — safe to send upstream."
  exit 0
fi

# ---- report ----------------------------------------------------------------
rc=0

if [ -n "$UNMANIFESTED" ]; then
  rc=1
  err "UNMANIFESTED upstream-owned divergence — add a row to ${MANIFEST#"$REPO_ROOT/"}:"
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
  err "STALE manifest row(s) in ${MANIFEST#"$REPO_ROOT/"} — the path no longer exists in the tree; upstream probably deleted or renamed it:"
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
  err "manifest guard FAILED — see ${MANIFEST#"$REPO_ROOT/"} (bead affine-hn1)."
fi
exit "$rc"
