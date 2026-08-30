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
echo "-- known-good: current tree passes"
run_guard
expect_rc 0 "clean"

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
# Uses a temp branch + --no-verify (the repo's husky pre-commit hook is not
# executable under Git-for-Windows) and never touches the checked-out branch.
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
FIXTURE_REF="$(git commit-tree "$tree" -p "$base_ref" -m 'guard live-edit fixture')"

run_guard --head "$FIXTURE_REF"
expect_rc 1 "policy violation"
expect_names "$VICTIM"

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
