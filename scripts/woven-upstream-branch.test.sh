#!/usr/bin/env bash
#
# woven-upstream-branch.test.sh — fixtures for the upstream branch preparer.
#
# Asserts the three properties that make the script worth having:
#   1. the branch it makes passes the outbound guard
#   2. the branch is named upstream/** so CI's trigger fires on it
#   3. naming a FORK-LOCAL file is refused, and NO branch is left behind
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

[ -x "$PREP" ]  || { echo "FATAL: $PREP missing or not executable" >&2; exit 2; }
[ -x "$GUARD" ] || { echo "FATAL: $GUARD missing or not executable" >&2; exit 2; }

TMPDIR_T="$(mktemp -d)"
BR_CLEAN="upstream/woven-prep-fixture-clean"
cleanup() { git branch -D "$BR_CLEAN" >/dev/null 2>&1 || true; rm -rf "$TMPDIR_T"; }
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

echo "== woven-upstream-branch fixtures =="

# --- 1. an ADDITIVE file produces a branch that passes the outbound guard ----
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
else
  bad "branch $BR_CLEAN was not created"; dump
fi

# --- 2. a FORK-LOCAL file is refused, and leaves nothing behind --------------
echo "-- refusal: a FORK-LOCAL CORE PATCH is rejected"
run_prep --no-switch "woven-prep-fixture-leak" "$OIDC_PATH"
if [ "$RC" -eq 1 ]; then ok "exit 1 (policy violation)"; else bad "exit $RC; expected 1"; dump; fi
if grep -qF -- "$OIDC_PATH" "$OUT"; then ok "output names $OIDC_PATH"; else bad "output does not name $OIDC_PATH"; dump; fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-leak" >/dev/null; then
  bad "a branch was left behind after a refusal"
  git branch -D "upstream/woven-prep-fixture-leak" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 3. usage errors are environment errors, not policy violations -----------
echo "-- usage: no files named"
run_prep --no-switch "woven-prep-fixture-empty"
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error)"; else bad "exit $RC; expected 2"; dump; fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
