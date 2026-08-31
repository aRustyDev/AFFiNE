#!/usr/bin/env bash
#
# woven-upstream-branch.test.sh — fixtures for the upstream branch preparer.
#
# Asserts the properties that make the script worth having:
#   1. the branch it makes passes the outbound guard, AND really carries the
#      content it was asked to carry (not merely a branch that happens to
#      exist — a tree byte-identical to the baseline satisfies every OTHER
#      assertion here too, which is exactly the bug this file used to miss)
#   2. the branch is named upstream/** so CI's trigger fires on it
#   3. naming a FORK-LOCAL file is refused — genuinely refused by the guard's
#      refusal, not merely logged as "carrying" before the guard ever ran —
#      and NO branch is left behind
#   4. an empty change set (named file(s) byte-identical to the baseline) is a
#      usage error, not a silent, unfalsifiable "safe to send upstream"
#   5. a dirty working tree and a nonexistent path are refused before
#      anything is built
#
# Exit codes match the guard's contract: 0 clean / 1 policy violation / 2 usage.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PREP="$REPO_ROOT/scripts/woven-upstream-branch.sh"
GUARD="$REPO_ROOT/scripts/woven-manifest-guard.sh"
OIDC_PATH="packages/backend/server/src/plugins/oauth/providers/oidc.ts"
ADD_PATH=".github/workflows/build-test.yml"
ADD_PATH2="packages/backend/server/src/seed/index.ts"
# Confirmed unchanged vs the baseline (see the report that drove this file):
# `git diff <baseline> HEAD -- $UNCHANGED_PATH` is empty. Any upstream-owned,
# non-fork-touched file works here; this one is stable dependency manifest.
UNCHANGED_PATH="packages/common/auth/package.json"

[ -x "$PREP" ]  || { echo "FATAL: $PREP missing or not executable" >&2; exit 2; }
[ -x "$GUARD" ] || { echo "FATAL: $GUARD missing or not executable" >&2; exit 2; }

TMPDIR_T="$(mktemp -d)"
BR_CLEAN="upstream/woven-prep-fixture-clean"
BR_TWO="upstream/woven-prep-fixture-two"
cleanup() {
  git branch -D "$BR_CLEAN" >/dev/null 2>&1 || true
  git branch -D "$BR_TWO"   >/dev/null 2>&1 || true
  # Safety net for the dirty-tree case below: it restores the file it dirtied
  # right after run_prep, but if the fixture is interrupted before that line
  # runs, this catches it too — scoped to the one file we ever touch, not a
  # blanket `checkout -- .` that could discard unrelated work.
  git checkout -- "$UNCHANGED_PATH" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR_T"
}
trap cleanup EXIT

# The preparer runs `git commit-tree`, which needs a git identity. A GitHub
# runner has none, and commit-tree then dies with "empty ident name" — the
# fixture would fail as exit 2 for a reason unrelated to what it tests. This is
# the same trap that broke the guard fixtures on run 33336365412; pass the
# identity through the environment rather than writing git config.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-woven-prep-fixture}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-fixture@woven.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-woven-prep-fixture}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-fixture@woven.invalid}"

PASS=0; FAIL=0
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
ok()  { printf '%s\n' "${c_grn}  ✔${c_rst} $*"; PASS=$((PASS+1)); }
bad() { printf '%s\n' "${c_red}  ✗${c_rst} $*" >&2; FAIL=$((FAIL+1)); }

OUT="$TMPDIR_T/out.txt"; RC=0
run_prep() { "$PREP" "$@" >"$OUT" 2>&1; RC=$?; }
dump()     { sed 's/^/     | /' "$OUT" >&2; }
blob_at()  { git ls-tree "$1" -- "$2" | awk '{print $3}'; }
no_refused_branches_left() {
  # Only the branches from cases that should have refused before creating
  # anything. BR_CLEAN and BR_TWO are legitimately created earlier in this
  # run and are cleaned up by the trap at script exit, not mid-run — checking
  # for them here would be checking a property this file never claimed.
  local left
  left="$(git for-each-ref --format='%(refname:short)' \
    'refs/heads/upstream/woven-prep-fixture-leak' \
    'refs/heads/upstream/woven-prep-fixture-noop' \
    'refs/heads/upstream/woven-prep-fixture-missing' \
    'refs/heads/upstream/woven-prep-fixture-dirty' \
    'refs/heads/upstream/woven-prep-fixture-empty')"
  [ -z "$left" ]
}

echo "== woven-upstream-branch fixtures =="

# --- 1. an ADDITIVE file produces a branch that ACTUALLY carries it ---------
echo "-- clean: one ADDITIVE file"
run_prep --no-switch "woven-prep-fixture-clean" "$ADD_PATH"
if [ "$RC" -eq 0 ]; then ok "exit 0"; else bad "exit $RC; expected 0"; dump; fi

if git rev-parse --verify --quiet "$BR_CLEAN" >/dev/null; then
  ok "branch $BR_CLEAN created"
  if "$GUARD" --outbound --head "$BR_CLEAN" >/dev/null 2>&1; then
    ok "the prepared branch passes the outbound guard"
  else
    bad "the prepared branch FAILS the outbound guard"
  fi
  # The branch must be based on the upstream baseline, not on woven/main: that
  # is the entire mechanism. Its parent is the baseline commit.
  BASE_SHA="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$REPO_ROOT/scripts/woven-upstream-baseline" | head -1)"
  parent="$(git rev-parse "${BR_CLEAN}^")"
  if [ "$parent" = "$(git rev-parse "$BASE_SHA")" ]; then
    ok "branch is based on UPSTREAM_COMMIT"
  else
    bad "branch parent is $parent, expected the baseline $BASE_SHA"
  fi
  # Passing the guard and having the right parent is satisfied by a branch
  # carrying NOTHING — both are also true of the empty baseline tree itself.
  # The only assertion that actually tests "did the named file get carried" is
  # looking inside the tree for it.
  want_blob="$(blob_at HEAD "$ADD_PATH")"
  got_blob="$(blob_at "$BR_CLEAN" "$ADD_PATH")"
  if [ -n "$want_blob" ] && [ "$got_blob" = "$want_blob" ]; then
    ok "branch tree contains $ADD_PATH at HEAD's content"
  else
    bad "branch tree does NOT contain $ADD_PATH (want blob $want_blob, got ${got_blob:-<absent>})"
  fi
else
  bad "branch $BR_CLEAN was not created"; dump
fi

# --- 1b. naming TWO files carries BOTH — the loop has a reason to exist -----
echo "-- clean: two ADDITIVE files"
run_prep --no-switch "woven-prep-fixture-two" "$ADD_PATH" "$ADD_PATH2"
if [ "$RC" -eq 0 ]; then ok "exit 0 (two files)"; else bad "exit $RC; expected 0"; dump; fi
if git rev-parse --verify --quiet "$BR_TWO" >/dev/null; then
  ok "branch $BR_TWO created"
  b1_want="$(blob_at HEAD "$ADD_PATH")";  b1_got="$(blob_at "$BR_TWO" "$ADD_PATH")"
  b2_want="$(blob_at HEAD "$ADD_PATH2")"; b2_got="$(blob_at "$BR_TWO" "$ADD_PATH2")"
  if [ -n "$b1_want" ] && [ "$b1_got" = "$b1_want" ]; then ok "carries $ADD_PATH"; else bad "missing/wrong $ADD_PATH (want $b1_want, got ${b1_got:-<absent>})"; fi
  if [ -n "$b2_want" ] && [ "$b2_got" = "$b2_want" ]; then ok "carries $ADD_PATH2"; else bad "missing/wrong $ADD_PATH2 (want $b2_want, got ${b2_got:-<absent>})"; fi
else
  bad "branch $BR_TWO was not created"; dump
fi

# --- 2. a FORK-LOCAL file is refused, and leaves nothing behind --------------
echo "-- refusal: a FORK-LOCAL CORE PATCH is rejected"
run_prep --no-switch "woven-prep-fixture-leak" "$OIDC_PATH"
if [ "$RC" -eq 1 ]; then ok "exit 1 (policy violation)"; else bad "exit $RC; expected 1"; dump; fi
# Grep for the GUARD's own refusal text, not the preparer's "carrying $p" log
# line — that line is written for every named path BEFORE the guard ever
# runs, so it names oidc.ts unconditionally and cannot distinguish a real
# refusal from a script that let everything through.
if grep -qF -- "FORK-LOCAL CORE PATCH on an upstream-directed change set" "$OUT" \
   && grep -qF -- "$OIDC_PATH" "$OUT"; then
  ok "guard's refusal names $OIDC_PATH"
else
  bad "output does not contain the guard's refusal naming $OIDC_PATH"; dump
fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-leak" >/dev/null; then
  bad "a branch was left behind after a refusal"
  git branch -D "upstream/woven-prep-fixture-leak" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 3. an empty change set is a usage error, not a silent success ----------
# This is the exact bug class that has recurred through this plan: a change
# set with nothing in it produces the SAME "clean" signal as "nothing to
# leak". Reproduction: $UNCHANGED_PATH is byte-identical between the baseline
# and HEAD, so the resulting tree is byte-identical to the baseline tree too.
echo "-- usage: named file is byte-identical to the baseline (empty change set)"
run_prep --no-switch "woven-prep-fixture-noop" "$UNCHANGED_PATH"
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error), not exit 0"; else bad "exit $RC; expected 2 — an empty change set must not report success"; dump; fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-noop" >/dev/null; then
  bad "a branch was left behind for an empty change set"
  git branch -D "upstream/woven-prep-fixture-noop" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 4. usage errors are environment errors, not policy violations -----------
echo "-- usage: no files named"
run_prep --no-switch "woven-prep-fixture-empty"
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error)"; else bad "exit $RC; expected 2"; dump; fi

echo "-- usage: named path does not exist at the ref"
run_prep --no-switch "woven-prep-fixture-missing" "packages/does/not/exist.ts"
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error)"; else bad "exit $RC; expected 2"; dump; fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-missing" >/dev/null; then
  bad "a branch was left behind for a nonexistent path"
  git branch -D "upstream/woven-prep-fixture-missing" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 5. a dirty working tree is refused before anything is built ------------
echo "-- usage: dirty working tree is refused"
echo "fixture scratch $$" >> "$UNCHANGED_PATH"
run_prep --no-switch "woven-prep-fixture-dirty" "$ADD_PATH"
git checkout -- "$UNCHANGED_PATH"
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error) on a dirty tree"; else bad "exit $RC; expected 2"; dump; fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-dirty" >/dev/null; then
  bad "a branch was left behind despite a dirty tree"
  git branch -D "upstream/woven-prep-fixture-dirty" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 6. none of the REFUSED cases left a branch behind, all together --------
# Each refusal case above already checks itself individually and cleans up
# after a false positive; this is a final cross-check that none of them
# slipped through together (e.g. a shared bug that only shows up once several
# refusals have run against the same repo state).
echo "-- hygiene: no refused-case branch outlives its own case"
if no_refused_branches_left; then ok "no stray refused-case branches remain"; else bad "a refused-case branch leaked past its own case"; git for-each-ref --format='%(refname)' 'refs/heads/upstream/woven-prep-fixture-*' >&2; fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
