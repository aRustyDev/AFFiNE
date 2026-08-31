#!/usr/bin/env bash
#
# woven-manifest-guard.test.sh — regression fixtures for the manifest CI guard.
#
# Fixtures are derived from real fork history, not synthesised:
#   * KNOWN-GOOD — woven/main @ 0761a62ba1 has exactly 3 upstream-owned diverged
#     files and the manifest has exactly 3 rows, so the guard must be silent.
#   * REGRESSION — affine-hn1.1 shipped a manifest that OMITTED
#     packages/backend/server/src/seed/index.ts. Deleting that row must make the
#     guard fail and name the path. This is the miss the guard exists to prevent.
#   * LIVE EDIT  — a real commit touching an unmanifested upstream-owned file,
#     built on a throwaway branch, proves the guard catches divergence and not
#     merely a doctored manifest.
#
# Exit codes asserted here are part of the guard's contract:
#   0 = clean   1 = policy violation   2 = usage / environment error
# Violations assert rc == 1 specifically, so a missing or crashing guard (127,
# 2) cannot satisfy a "must fail" fixture vacuously.
#
# Usage: scripts/woven-manifest-guard.test.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GUARD="$REPO_ROOT/scripts/woven-manifest-guard.sh"
MANIFEST="$REPO_ROOT/scripts/woven-patch-manifest.md"
SEED_PATH="packages/backend/server/src/seed/index.ts"
OIDC_PATH="packages/backend/server/src/plugins/oauth/providers/oidc.ts"

[ -x "$GUARD" ] || { echo "FATAL: $GUARD missing or not executable" >&2; exit 2; }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

PASS=0; FAIL=0
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
ok()  { printf '%s\n' "${c_grn}  ✔${c_rst} $*"; PASS=$((PASS+1)); }
bad() { printf '%s\n' "${c_red}  ✗${c_rst} $*" >&2; FAIL=$((FAIL+1)); }

OUT=""; RC=0
N=0
run_guard() { N=$((N+1)); OUT="$TMPDIR_T/out.$N.txt"; "$GUARD" "$@" >"$OUT" 2>&1; RC=$?; }
dump()      { sed 's/^/     | /' "$OUT" >&2; }

expect_rc() {
  if [ "$RC" -eq "$1" ]; then ok "exit $1${2:+ ($2)}"; else bad "exit $RC; expected $1${2:+ ($2)}"; dump; fi
}
expect_names() {
  local p
  for p in "$@"; do
    if grep -qF -- "$p" "$OUT"; then ok "output names $p"; else bad "output does not name $p"; dump; fi
  done
}

echo "== woven-manifest-guard fixtures =="

# --- 1. known-good tree: 3 upstream-owned diverged files, 3 manifest rows -----
# --head is explicit so this stays a statement about the COMMITTED tree even when
# the developer running it has unrelated edits in progress.
echo "-- known-good: committed tree passes"
run_guard --head HEAD
expect_rc 0 "clean"

# --- 1b. uncommitted edits are seen ------------------------------------------
# Run locally before committing, a guard that only ever diffs HEAD reports "clean"
# on the very change you are about to push. That is the miss this whole epic
# exists to prevent, so with no explicit --head the guard must fold the working
# tree in. Uses a tracked, upstream-owned, currently-unmanifested victim and puts
# it back afterwards.
echo "-- worktree: an uncommitted edit to an unmanifested upstream-owned file"
WT_VICTIM="packages/backend/server/src/base/error/def.ts"
if ! git diff --quiet -- "$WT_VICTIM" 2>/dev/null; then
  bad "$WT_VICTIM already has uncommitted changes; skipping to avoid clobbering them"
else
  restore_victim() { git checkout -- "$WT_VICTIM" 2>/dev/null || true; }
  trap 'restore_victim; rm -rf "$TMPDIR_T"' EXIT
  printf '\n// woven guard worktree fixture\n' >> "$WT_VICTIM"
  run_guard
  expect_rc 1 "policy violation"
  expect_names "$WT_VICTIM"
  restore_victim
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

# --- 2. the affine-hn1.1 miss is now caught ----------------------------------
echo "-- regression: seed/index.ts row deleted (the affine-hn1.1 miss)"
grep -v -- "src/seed/index.ts" "$MANIFEST" >"$TMPDIR_T/m-seed.md"
run_guard --manifest "$TMPDIR_T/m-seed.md"
expect_rc 1 "policy violation"
expect_names "$SEED_PATH"

# --- 3. every offending path is named, not just the first --------------------
echo "-- completeness: two rows deleted -> both paths named"
grep -v -e "src/seed/index.ts" -e "providers/oidc.ts" "$MANIFEST" >"$TMPDIR_T/m-two.md"
run_guard --manifest "$TMPDIR_T/m-two.md"
expect_rc 1 "policy violation"
expect_names "$SEED_PATH" "$OIDC_PATH"

# --- 4. stale manifest row (path no longer in the tree) ----------------------
echo "-- stale row: manifest cites a path that no longer exists"
GHOST="packages/backend/server/src/deleted-by-upstream.ts"
sed "s|\`$OIDC_PATH\`|\`$GHOST\`|" "$MANIFEST" >"$TMPDIR_T/m-stale.md"
run_guard --manifest "$TMPDIR_T/m-stale.md"
expect_rc 1 "policy violation"
expect_names "$GHOST"

# --- 5. unresolvable baseline fails loudly rather than passing vacuously -----
echo "-- bad baseline: unknown ref is an environment error, not a pass"
run_guard --base 0000000000000000000000000000000000000000
expect_rc 2 "environment error"

# --- 6. a REAL unmanifested edit, on a throwaway commit ----------------------
# Built with plumbing against a scratch index, so no branch, index or working
# tree is touched and no hooks run.
echo "-- live edit: real commit touching an unmanifested upstream-owned file"
VICTIM="packages/backend/server/src/base/error/def.ts"
base_ref="$(git rev-parse HEAD)"
tmp_index="$TMPDIR_T/index"
# Built entirely with plumbing against a scratch index seeded from HEAD, so the
# branch, the real index and the working tree are never touched — this is
# deliberately safe to run on a dirty tree.
blob="$(printf '// woven guard live-edit fixture\n' | git hash-object -w --stdin)"
GIT_INDEX_FILE="$tmp_index" git read-tree "$base_ref"
GIT_INDEX_FILE="$tmp_index" git update-index --add --cacheinfo "100644,$blob,$VICTIM"
tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
# The identity comes from the environment, not `git config`: a GitHub runner has
# no user.name/user.email, and commit-tree then dies with "empty ident name",
# leaving FIXTURE_REF empty and the fixture failing for the wrong reason.
FIXTURE_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
               GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
               git commit-tree "$tree" -p "$base_ref" -m 'guard live-edit fixture')"

if [ -z "$FIXTURE_REF" ]; then
  bad "could not build the live-edit fixture commit (git commit-tree produced nothing)"
else
  run_guard --head "$FIXTURE_REF"
  expect_rc 1 "policy violation"
  expect_names "$VICTIM"
fi

echo "== woven-manifest-guard OUTBOUND fixtures =="

# --- 7. the flag exists -------------------------------------------------------
# Only asserts "not a usage error" (rc != 2), not "clean" (rc == 0): once Task 3
# lands the actual outbound check, this same invocation is expected to fail with
# rc 1 against woven/main's real oidc.ts fork-local patch. That is correct
# behaviour for the finished guard, not a regression in this fixture.
echo "-- outbound: --outbound is accepted"
run_guard --outbound --head HEAD
if [ "$RC" -ne 2 ]; then ok "--outbound accepted (exit $RC, not a usage error)"
else bad "--outbound rejected as a usage error"; dump; fi

# --- 8. fail closed: an unrecognised category is an ENVIRONMENT error --------
# Never "assume ADDITIVE". A typo in column 2 must not silently open the gate —
# that is the one parsing bug that would be both invisible and catastrophic.
echo "-- fail closed: garbage category exits 2, not 0 or 1"
sed 's|\*\*FORK-LOCAL CORE PATCH\*\*|**FORK LOCAL CORE PATCH**|' "$MANIFEST" >"$TMPDIR_T/m-badcat.md"
run_guard --outbound --manifest "$TMPDIR_T/m-badcat.md" --head HEAD
expect_rc 2 "environment error"
expect_names "$OIDC_PATH"

# --- 9. the same bad category, INBOUND -----------------------------------
# The category check runs before the inbound/outbound branch, so a broken
# manifest must exit 2 regardless of direction — not just under --outbound.
echo "-- fail closed: garbage category exits 2 inbound too, not just outbound"
run_guard --manifest "$TMPDIR_T/m-badcat.md" --head HEAD
expect_rc 2 "environment error"
expect_names "$OIDC_PATH"

# --- 10. fail closed: a data row that lost its backticks must not vanish -----
# Before this fixture, split(...) < 3 fields (or a missing backtick) made a row
# disappear silently — landing in neither MANIFESTED nor FORKLOCAL. Today
# inbound still catches the resulting UNMANIFESTED file, but Task 3's outbound
# check trusts absence-from-FORKLOCAL as "safe to send upstream", so a silently
# dropped FORK-LOCAL CORE PATCH row would fail OPEN there.
echo "-- fail closed: a data row missing its backticks exits 2, not silently dropped"
sed "s|\`$OIDC_PATH\`|$OIDC_PATH|" "$MANIFEST" >"$TMPDIR_T/m-nobacktick.md"
run_guard --manifest "$TMPDIR_T/m-nobacktick.md" --head HEAD
expect_rc 2 "environment error"
expect_names "$OIDC_PATH"

# --- 11. fail closed: an empty manifest table is fatal under --outbound ------
# Renaming the section heading makes manifest_rows emit nothing at all — no
# BADCAT, no UNPARSED, just an empty table. Inbound only warns (existing rows
# still get caught as UNMANIFESTED elsewhere), but outbound has nothing else to
# catch it: comm against an empty FORKLOCAL says "safe", which is exactly
# backwards for a guard that protects nothing.
echo "-- fail closed: renamed section heading (empty manifest) exits 2 under --outbound"
sed 's|^## Diverged upstream-owned files|## Renamed by mistake|' "$MANIFEST" >"$TMPDIR_T/m-renamed.md"
run_guard --outbound --manifest "$TMPDIR_T/m-renamed.md" --head HEAD
expect_rc 2 "environment error"

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
