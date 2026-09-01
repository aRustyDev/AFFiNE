#!/usr/bin/env bash
#
# woven-upstream-branch.test.sh — fixtures for the upstream branch preparer.
#
# Asserts the properties that make the script worth having:
#   1. the branch it makes passes the outbound guard, AND really carries the
#      content it was asked to carry (not merely a branch that happens to
#      exist — a tree byte-identical to the baseline satisfies every OTHER
#      assertion here too, which is exactly the bug this file used to miss)
#   2. the branch is named upstream/** so CI's trigger fires on it, and a
#      same-named remote-tracking ref cannot block that
#   3. naming a FORK-LOCAL file is refused — genuinely refused by the guard's
#      refusal, not merely logged as "carrying" before the guard ever ran —
#      and NO branch is left behind
#   4. an empty change set (named file(s) byte-identical to the baseline) is a
#      usage error, not a silent, unfalsifiable "safe to send upstream"; a
#      PARTLY empty one is reported honestly rather than left to contradict
#      the guard's own "N changed vs baseline" line
#   5. a dirty working tree, a nonexistent path, and a directory are all
#      refused before anything is built
#   6. the guard's own 0/1/2 exit contract survives the dispatch in this
#      script unmangled (via the WOVEN_GUARD stub seam), and --from / --help
#      actually do what the header says
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
DIR_PATH="packages/common/auth"
# Any upstream-owned, non-fork-touched file works as the "byte-identical to
# the baseline" fixture path. Checked below at RUNTIME, not just asserted in
# a comment — a comment pointing at "the report that drove this file" is
# something a future reader cannot go find.
UNCHANGED_PATH="packages/common/auth/package.json"
# A commit where scripts/woven-upstream-baseline's content differs from both
# HEAD's and the upstream baseline's (the file doesn't exist upstream at all,
# so it's fork-owned) — used to prove --from selects THAT ref's content.
FROM_TEST_PATH="scripts/woven-upstream-baseline"
FROM_TEST_REF="c61756df72"

[ -x "$PREP" ]  || { echo "FATAL: $PREP missing or not executable" >&2; exit 2; }
[ -x "$GUARD" ] || { echo "FATAL: $GUARD missing or not executable" >&2; exit 2; }

BASE_SHA="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$REPO_ROOT/scripts/woven-upstream-baseline" | head -1)"
[ -n "$BASE_SHA" ] || { echo "FATAL: could not read UPSTREAM_COMMIT from scripts/woven-upstream-baseline" >&2; exit 2; }

# Runtime precondition for the empty-change-set fixture below: if this ever
# stops holding (upstream baseline moves, the file is edited), that fixture
# would silently degrade into testing nothing instead of the case it claims
# to. Fail loudly and name a fix, rather than trusting a comment.
base_blob_precheck="$(git rev-parse --verify --quiet "${BASE_SHA}:${UNCHANGED_PATH}" 2>/dev/null || true)"
head_blob_precheck="$(git rev-parse --verify --quiet "HEAD:${UNCHANGED_PATH}" 2>/dev/null || true)"
if [ -z "$base_blob_precheck" ] || [ "$base_blob_precheck" != "$head_blob_precheck" ]; then
  echo "FATAL: fixture precondition failed — $UNCHANGED_PATH is expected to be byte-identical between the baseline ($BASE_SHA) and HEAD, but it is not (baseline blob '${base_blob_precheck:-<absent>}', HEAD blob '${head_blob_precheck:-<absent>}'). Pick a different UNCHANGED_PATH." >&2
  exit 2
fi

# Refuse to run on a dirty tree UP FRONT, rather than repairing one. Several
# fixtures below depend on a clean tree already (the preparer itself refuses
# a dirty tree), and this suite's OWN dirty-tree fixture temporarily edits a
# tracked file — restoring it later is that fixture's job, not a reason for
# this suite to silently tidy up a tree it did not dirty. A prior version of
# this file ran `git checkout -- "$UNCHANGED_PATH"` unconditionally in its
# EXIT trap and ate a developer's real, unrelated edit to that same file with
# zero explanation beyond a wall of unrelated-looking failures.
dirty_status_precheck="$(git status --porcelain --untracked-files=no)"; dirty_rc_precheck=$?
if [ "$dirty_rc_precheck" -ne 0 ] || [ -n "$dirty_status_precheck" ]; then
  echo "FATAL: working tree is dirty — commit or stash your changes before running this suite." >&2
  echo "This suite will not repair a dirty tree for you; several fixtures below assume one already, and one of them edits a tracked file itself." >&2
  [ -n "$dirty_status_precheck" ] && printf '%s\n' "$dirty_status_precheck" >&2
  exit 2
fi

TMPDIR_T="$(mktemp -d)"
BR_CLEAN="upstream/woven-prep-fixture-clean"
BR_TWO="upstream/woven-prep-fixture-two"
DIRTIED=0
cleanup() {
  git branch -D "$BR_CLEAN" >/dev/null 2>&1 || true
  git branch -D "$BR_TWO"   >/dev/null 2>&1 || true
  # Only restore the file THIS suite dirtied, and only if it actually did —
  # not unconditionally on every exit. See the note above the dirty-tree
  # precheck for what an unconditional version of this line already cost.
  if [ "$DIRTIED" -eq 1 ]; then
    git checkout -- "$UNCHANGED_PATH" >/dev/null 2>&1 || true
  fi
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
blob_at()  {
  # Deliberately `ls-tree <ref> -- <path>`, NOT `rev-parse <ref>:<path>`: under
  # git-bash/MSYS, the automatic argument path-conversion mangles a single
  # <ref>:<path> argument whenever <ref> itself contains a slash (every branch
  # this file creates does — upstream/<name>) — confirmed by hand, and only
  # when the ref side has a "/"; a plain SHA or a slash-free branch name on
  # the left of the colon is unaffected. Passed as two separate argv entries,
  # ls-tree never hits that mangling.
  git ls-tree "$1" -- "$2" | awk '{print $3}'
}
no_refused_branches_left() {
  # Only the branches from cases that should have refused before creating
  # anything. BR_CLEAN and BR_TWO are legitimately created earlier in this
  # run and are cleaned up by the trap at script exit, not mid-run.
  local left
  left="$(git for-each-ref --format='%(refname:short)' \
    'refs/heads/upstream/woven-prep-fixture-leak' \
    'refs/heads/upstream/woven-prep-fixture-noop' \
    'refs/heads/upstream/woven-prep-fixture-missing' \
    'refs/heads/upstream/woven-prep-fixture-dirty' \
    'refs/heads/upstream/woven-prep-fixture-empty' \
    'refs/heads/upstream/woven-prep-fixture-dir' \
    'refs/heads/upstream/woven-prep-fixture-stubrc1' \
    'refs/heads/upstream/woven-prep-fixture-stubrc2')"
  [ -z "$left" ]
}

# Three-line stub guards for the WOVEN_GUARD testing seam: the real guard's
# exit-2 paths (unresolvable baseline, unparseable manifest row) are not
# otherwise reachable without dirtying the tree the preparer itself refuses to
# run against, so the dispatch fix (capture rc, switch on 0/1/2 explicitly)
# would otherwise ship with no fixture that could ever catch it regressing —
# and it did regress silently once already (collapsed back to `if ! "$GUARD"`
# and still passed 20/20).
STUB_RC1="$TMPDIR_T/stub-guard-rc1.sh"
cat > "$STUB_RC1" <<'EOF'
#!/usr/bin/env bash
echo "STUB GUARD: simulated FORK-LOCAL CORE PATCH refusal (rc=1) for test purposes"
exit 1
EOF
chmod +x "$STUB_RC1"

STUB_RC2="$TMPDIR_T/stub-guard-rc2.sh"
cat > "$STUB_RC2" <<'EOF'
#!/usr/bin/env bash
echo "STUB GUARD: simulated environment error (rc=2) for test purposes" >&2
exit 2
EOF
chmod +x "$STUB_RC2"

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
# leak". Reproduction: $UNCHANGED_PATH is checked above (at runtime) to be
# byte-identical between the baseline and HEAD, so the resulting tree is
# byte-identical to the baseline tree too.
echo "-- usage: named file is byte-identical to the baseline (empty change set)"
run_prep --no-switch "woven-prep-fixture-noop" "$UNCHANGED_PATH"
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error), not exit 0"; else bad "exit $RC; expected 2 — an empty change set must not report success"; dump; fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-noop" >/dev/null; then
  bad "a branch was left behind for an empty change set"
  git branch -D "upstream/woven-prep-fixture-noop" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 3b. a PARTLY empty change set is reported honestly, not silently -------
# The all-or-nothing check above cannot see this: one file is a real change,
# the other is a no-op, and the branch is legitimately created — but the
# operator should not have to cross-read the guard's "N changed vs baseline"
# line against this script's "created ... with N file(s)" to notice the
# second file did nothing.
echo "-- partial no-op: one real change plus one baseline-identical file"
run_prep --no-switch "woven-prep-fixture-partial" "$ADD_PATH" "$UNCHANGED_PATH"
if [ "$RC" -eq 0 ]; then ok "exit 0 (one real change is enough to proceed)"; else bad "exit $RC; expected 0"; dump; fi
if grep -qF -- "$UNCHANGED_PATH is byte-identical to the baseline" "$OUT"; then
  ok "warns about the no-op path by name"
else
  bad "no per-path warning about the no-op path"; dump
fi
if grep -qE '2 file\(s\), 1 differ from the baseline' "$OUT"; then
  ok "summary line distinguishes carried count from differing count"
else
  bad "summary line does not distinguish carried from differing"; dump
fi
git branch -D "upstream/woven-prep-fixture-partial" >/dev/null 2>&1 || true

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

echo "-- usage: naming a directory is refused, not silently mis-carried"
run_prep --no-switch "woven-prep-fixture-dir" "$DIR_PATH"
if [ "$RC" -eq 2 ]; then ok "exit 2 for a directory path"; else bad "exit $RC; expected 2"; dump; fi
# Grep the mode-allowlist's OWN message, not just the exit code: `--cacheinfo`
# happens to also reject mode 040000 with its own raw plumbing error ("could
# not stage $p"), which is a different message that also exits 2 — so a
# bare exit-code check here cannot tell the intentional guard apart from that
# coincidence, and cannot catch the guard being removed. It also would not
# catch the 160000 (gitlink) half of this same guard at all, since
# --cacheinfo ACCEPTS that mode with no error of its own.
if grep -qF -- "not a regular file at HEAD: $DIR_PATH" "$OUT"; then
  ok "refused by the mode allowlist specifically, not by git's incidental --cacheinfo error"
else
  bad "mode-allowlist message missing — a directory may be getting caught only by --cacheinfo's own error, or not caught by the intended guard at all"; dump
fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-dir" >/dev/null; then
  bad "a branch was left behind for a directory path"
  git branch -D "upstream/woven-prep-fixture-dir" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 5. a dirty working tree is refused before anything is built ------------
echo "-- usage: dirty working tree is refused"
DIRTIED=1
echo "fixture scratch $$" >> "$UNCHANGED_PATH"
run_prep --no-switch "woven-prep-fixture-dirty" "$ADD_PATH"
git checkout -- "$UNCHANGED_PATH"
DIRTIED=0
if [ "$RC" -eq 2 ]; then ok "exit 2 (usage error) on a dirty tree"; else bad "exit $RC; expected 2"; dump; fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-dirty" >/dev/null; then
  bad "a branch was left behind despite a dirty tree"
  git branch -D "upstream/woven-prep-fixture-dirty" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 6. refs/heads anchoring: a same-named remote-tracking ref must not ------
#        block branch creation. Synthesized rather than relying on this
#        checkout actually having fetched refs/remotes/upstream/*, so the
#        fixture is deterministic in any clone, not just a dev workstation
#        with an `upstream` remote configured.
echo "-- refs/heads anchoring: a same-named remote-tracking ref is not the local branch"
SYNTHETIC_REF="refs/remotes/upstream/woven-prep-fixture-anchor"
git update-ref "$SYNTHETIC_REF" "$(git rev-parse HEAD)"
run_prep --no-switch "woven-prep-fixture-anchor" "$ADD_PATH"
if [ "$RC" -eq 0 ]; then
  ok "creates upstream/woven-prep-fixture-anchor despite a same-named remote-tracking ref"
else
  bad "exit $RC; expected 0 — the refs/heads anchoring regressed"; dump
fi
git branch -D "upstream/woven-prep-fixture-anchor" >/dev/null 2>&1 || true
git update-ref -d "$SYNTHETIC_REF" >/dev/null 2>&1 || true

# --- 7. the guard's 0/1/2 contract survives the dispatch, via a stub --------
echo "-- guard dispatch: a stub guard exiting 1 propagates as exit 1"
WOVEN_GUARD="$STUB_RC1" run_prep --no-switch "woven-prep-fixture-stubrc1" "$ADD_PATH"
if [ "$RC" -eq 1 ]; then ok "exit 1"; else bad "exit $RC; expected 1"; dump; fi
if grep -qF -- "refusing to create upstream/woven-prep-fixture-stubrc1" "$OUT"; then
  ok "refusal message names the branch"
else
  bad "missing the rc=1 refusal message"; dump
fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-stubrc1" >/dev/null; then
  bad "a branch was left behind under a stub rc=1 guard"
  git branch -D "upstream/woven-prep-fixture-stubrc1" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

echo "-- guard dispatch: a stub guard exiting 2 propagates as exit 2, NOT exit 1"
WOVEN_GUARD="$STUB_RC2" run_prep --no-switch "woven-prep-fixture-stubrc2" "$ADD_PATH"
if [ "$RC" -eq 2 ]; then ok "exit 2, not collapsed into a policy violation"; else bad "exit $RC; expected 2"; dump; fi
if grep -qF -- "the guard could not judge this branch (exit 2)" "$OUT"; then
  ok "message says the guard could not judge, not that a file leaked"
else
  bad "missing the rc=2 dispatch message — a usage error must not look like a policy violation"; dump
fi
if git rev-parse --verify --quiet "upstream/woven-prep-fixture-stubrc2" >/dev/null; then
  bad "a branch was left behind under a stub rc=2 guard"
  git branch -D "upstream/woven-prep-fixture-stubrc2" >/dev/null 2>&1 || true
else
  ok "no branch left behind"
fi

# --- 8. --from selects THAT ref's content, not HEAD's -----------------------
echo "-- --from: pulls content from the named ref, not from HEAD"
run_prep --no-switch --from "$FROM_TEST_REF" "woven-prep-fixture-from" "$FROM_TEST_PATH"
if [ "$RC" -eq 0 ]; then ok "exit 0 (--from ref resolved)"; else bad "exit $RC; expected 0"; dump; fi
from_want="$(blob_at "$FROM_TEST_REF" "$FROM_TEST_PATH")"
from_head="$(blob_at HEAD "$FROM_TEST_PATH")"
from_got="$(blob_at "upstream/woven-prep-fixture-from" "$FROM_TEST_PATH")"
if [ -n "$from_want" ] && [ "$from_got" = "$from_want" ] && [ "$from_got" != "$from_head" ]; then
  ok "branch carries ${FROM_TEST_REF}'s content for $FROM_TEST_PATH, not HEAD's"
else
  bad "branch does not carry --from's content (want $from_want, got ${from_got:-<absent>}, HEAD is $from_head)"
fi
git branch -D "upstream/woven-prep-fixture-from" >/dev/null 2>&1 || true

# --- 9. -h/--help actually prints usage and exits 0 --------------------------
echo "-- -h/--help exits 0 and prints usage text"
"$PREP" --help >"$OUT" 2>&1; RC=$?
if [ "$RC" -eq 0 ]; then ok "exit 0 for --help"; else bad "exit $RC; expected 0"; dump; fi
if grep -qi "^# Usage:" "$OUT"; then ok "prints the usage block"; else bad "no usage text printed"; dump; fi

# --- 10. none of the REFUSED cases left a branch behind, all together -------
# Each refusal case above already checks itself individually and cleans up
# after a false positive; this is a final cross-check that none of them
# slipped through together.
echo "-- hygiene: no refused-case branch outlives its own case"
if no_refused_branches_left; then ok "no stray refused-case branches remain"; else bad "a refused-case branch leaked past its own case"; git for-each-ref --format='%(refname)' 'refs/heads/upstream/woven-prep-fixture-*' >&2; fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
