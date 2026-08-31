#!/usr/bin/env bash
#
# woven-upstream-branch.sh — start a branch destined for upstream, based on the
# UPSTREAM BASELINE rather than on woven/main.
#
# A branch cut from woven/main carries every fork-local patch the fork has ever
# made, including the oidc.ts core auth patch. That is the ordinary shape of
# forking and it is how a fork-local patch reaches an upstream PR. Branching from
# scripts/woven-upstream-baseline's UPSTREAM_COMMIT instead means there is
# nothing to leak: prevention by construction, not detection afterwards.
#
# The branch is a STARTING POINT. You will review it, cherry-pick, edit and
# squash before pushing — so the clean result reported here does not describe the
# branch you eventually push. .husky/pre-push and the CI job on upstream/** are
# what check the final content.
#
# Names the branch upstream/<name>, which is the prefix the CI backstop keys on.
#
# EXIT CODES (match woven-manifest-guard.sh)
#   0  branch created and clean
#   1  refused — a named file is a FORK-LOCAL CORE PATCH
#   2  usage or environment error
#
# Usage:
#   scripts/woven-upstream-branch.sh [--from REF] [--no-switch] <name> <path>...
#
#   --from REF    take the file contents from REF (default: HEAD)
#   --no-switch   create the branch but stay where you are (used by the fixtures)
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

GUARD="$REPO_ROOT/scripts/woven-manifest-guard.sh"
BASELINE_FILE="$REPO_ROOT/scripts/woven-upstream-baseline"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s\n' "${c_cyn}[upstream-branch]${c_rst} $*"; }
ok()   { printf '%s\n' "${c_grn}[upstream-branch] ✔${c_rst} $*"; }
err()  { printf '%s\n' "${c_red}[upstream-branch] ✗${c_rst} $*" >&2; }
die()  { err "$*"; exit 2; }

FROM="HEAD"
SWITCH=1
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from)      [ $# -ge 2 ] || die "--from needs a ref"; FROM="$2"; shift 2 ;;
    --no-switch) SWITCH=0; shift ;;
    -h|--help)   awk 'NR>1 && !/^#/{exit} NR>1' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          die "unknown argument: $1" ;;
    *)           NAME="$1"; shift; break ;;
  esac
done

[ -n "$NAME" ] || die "usage: scripts/woven-upstream-branch.sh <name> <path>..."
[ $# -ge 1 ]   || die "name at least one file to carry over"
[ -x "$GUARD" ] || die "guard not found or not executable: $GUARD"
[ -f "$BASELINE_FILE" ] || die "baseline file not found: $BASELINE_FILE"

[ -z "$(git status --porcelain --untracked-files=no)" ] || \
  die "working tree is dirty — commit or set aside your changes first"

BASE="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$BASELINE_FILE" | head -1)"
[ -n "$BASE" ] || die "UPSTREAM_COMMIT missing from $BASELINE_FILE"
BASE_SHA="$(git rev-parse --verify --quiet "${BASE}^{commit}" || true)"
[ -n "$BASE_SHA" ] || die "cannot resolve the upstream baseline '$BASE' — is this a full-history checkout?"

FROM_SHA="$(git rev-parse --verify --quiet "${FROM}^{commit}" || true)"
[ -n "$FROM_SHA" ] || die "cannot resolve --from ref '$FROM'"

BRANCH="upstream/${NAME}"
# refs/heads/ anchored: an unanchored `git rev-parse --verify` also resolves
# refs/remotes/<remote>/<name> — a remote literally named "upstream" makes
# upstream/canary and upstream/HEAD resolve as if a LOCAL branch already
# existed, refusing the exact names a contributor reaches for first even
# though `git branch "$BRANCH"` below would have been perfectly happy.
git show-ref --verify --quiet "refs/heads/$BRANCH" && die "branch $BRANCH already exists"

# Build the candidate commit with plumbing against a scratch index, so nothing
# exists to clean up if the guard refuses it.
TMP_INDEX="$(mktemp -u)"
trap 'rm -f "$TMP_INDEX"' EXIT
GIT_INDEX_FILE="$TMP_INDEX" git read-tree "$BASE_SHA" || die "could not seed a scratch index from the baseline"

CARRIED_PATHS=()
for p in "$@"; do
  entry="$(git ls-tree "$FROM_SHA" -- "$p")"
  [ -n "$entry" ] || die "no such file at ${FROM}: $p"
  mode="$(printf '%s' "$entry" | awk '{print $1}')"
  blob="$(printf '%s' "$entry" | awk '{print $3}')"
  # A directory (mode 040000) or gitlink (mode 160000) must be rejected on
  # purpose, not by accident. `git ls-tree REF -- path` on a directory returns
  # a single well-formed 040000 line — [-n "$entry"] alone does not catch it —
  # and while --cacheinfo happens to reject 040000 with git's raw plumbing
  # error, it ACCEPTS 160000 (a gitlink/submodule commit reference), silently
  # carrying a submodule pointer instead of the file the operator named.
  case "$mode" in
    100644|100755|120000) ;;
    *) die "not a regular file at ${FROM}: $p (mode $mode)" ;;
  esac
  GIT_INDEX_FILE="$TMP_INDEX" git update-index --add --cacheinfo "${mode},${blob},${p}" \
    || die "could not stage $p"
  CARRIED_PATHS+=("$p")
  log "carrying $p"
done

TREE="$(GIT_INDEX_FILE="$TMP_INDEX" git write-tree)"
[ -n "$TREE" ] || die "could not write the candidate tree"

# A tree byte-identical to the baseline is not "nothing to leak" — it is
# nothing at all. Without this check a mistyped --from, a fix already merged
# upstream, or simply running from a checkout sitting at the baseline all
# produce the SAME green "safe to send upstream" signal as a real, reviewed
# change: the guard has nothing to compare because there is no divergence to
# see. A branch that carries no content is a usage error, not a clean result.
BASE_TREE="$(git rev-parse "${BASE_SHA}^{tree}")"
[ "$TREE" != "$BASE_TREE" ] || \
  die "the named file(s) are byte-identical to the baseline ${BASE:0:9} — nothing to carry upstream. Check --from and the path(s) named."

COMMIT="$(git commit-tree "$TREE" -p "$BASE_SHA" -m "${NAME}: prepared for upstream from ${BASE:0:9}")"
[ -n "$COMMIT" ] || die "could not build the candidate commit"

# One definition of "is this a leak", and it is not in this file. The guard's
# own exit-code contract is 0 clean / 1 policy violation / 2 usage-or-environment
# error — collapsing those with a bare `if !` would report an unresolvable
# baseline or an unparseable manifest row (exit 2) as "your file is a
# fork-local patch" (exit 1), which is a misdiagnosis even though it happens to
# fail closed either way. Capture the real code and dispatch on it explicitly.
"$GUARD" --outbound --head "$COMMIT"
guard_rc=$?
case "$guard_rc" in
  0) : ;;
  1)
    err "refusing to create $BRANCH — see the guard output above."
    exit 1
    ;;
  *)
    err "the guard could not judge this branch (exit $guard_rc) — see the guard output above."
    exit 2
    ;;
esac

git branch "$BRANCH" "$COMMIT" || die "could not create $BRANCH"
# Count what was actually staged, not argv: naming the same path twice would
# otherwise report "2 file(s)" for a tree that carries one.
n_carried="$(printf '%s\n' "${CARRIED_PATHS[@]}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
ok "created $BRANCH from ${BASE:0:9} with $n_carried file(s)"

if [ "$SWITCH" -eq 1 ]; then
  git switch "$BRANCH" || die "branch created but could not switch to it"
fi

log "This branch is a STARTING POINT — review, cherry-pick and squash as needed."
log "pre-push re-checks it against \$UPSTREAM_REPO before it leaves your machine."
exit 0
