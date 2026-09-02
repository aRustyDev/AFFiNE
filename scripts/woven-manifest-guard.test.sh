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

# --- affine-83p shared fixture helpers ---------------------------------------
MOVED_DEST="packages/backend/server/src/plugins/oauth/providers/woven-oidc.ts"

mark_removed() {  # $1 = path to mark, $2 = output manifest
  awk -v p="$1" '
    $0 ~ p && /^\|/ { sub(/[[:space:]]*\|[[:space:]]*$/, " | **REMOVED** |"); }
    { print }
  ' "$MANIFEST" >"$2"
}
mark_moved() {  # $1 = source, $2 = destination, $3 = output manifest
  awk -v p="$1" -v dst="$2" '
    $0 ~ p && /^\|/ { sub(/[[:space:]]*\|[[:space:]]*$/, " | **MOVED** `" dst "` |"); }
    { print }
  ' "$MANIFEST" >"$3"
}
restore_oidc() { git checkout -- "$OIDC_PATH" 2>/dev/null || true; }
restore_seed() { git checkout -- "$SEED_PATH" 2>/dev/null || true; }
restore_move() {
  git reset -q -- "$OIDC_PATH" "$MOVED_DEST" 2>/dev/null || true
  rm -f "$MOVED_DEST"
  git checkout -- "$OIDC_PATH" 2>/dev/null || true
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

# --- 12. --dump-rows exposes the classifier's real pairing (mutation-tests the case) --
# FORKLOCAL is otherwise write-only: nothing else in the suite reads it, so
# swapping the ADDITIVE / FORK-LOCAL CORE PATCH arms of the classifier's `case`
# — a full inversion of the guard's purpose — would still print all-green.
# --dump-rows is built inside the SAME case dispatch that fills FORKLOCAL (not
# a second, driftable read of the raw manifest text), so an inverted arm
# changes what gets printed here too — verified by hand: swapping the arms
# flips oidc.ts to ADDITIVE and the other two rows to FORK-LOCAL CORE PATCH,
# which this assertion would catch.
echo "-- dump-rows: real manifest pairs each path with its actual classified category"
run_guard --dump-rows --head HEAD
expect_rc 0 "clean"
DUMP_LINES="$(grep -F "$(printf '\t')" "$OUT" | sort)"
# The live manifest has no State column, so every row defaults to PRESENT with
# no destination — the fail-closed default this whole change must preserve.
EXPECT_LINES="$(printf '%s\n' \
  "$OIDC_PATH"$'\t'"FORK-LOCAL CORE PATCH"$'\t'"PRESENT"$'\t' \
  ".github/workflows/build-test.yml"$'\t'"ADDITIVE"$'\t'"PRESENT"$'\t' \
  "$SEED_PATH"$'\t'"ADDITIVE"$'\t'"PRESENT"$'\t' | sort)"
if [ "$DUMP_LINES" = "$EXPECT_LINES" ]; then
  ok "dump-rows pairs all 3 rows with the correct classified category, nothing more or less"
else
  bad "dump-rows output does not match the expected (path, category) pairing"
  dump
fi

# --- 13. the leak: a branch off woven/main carries the core auth patch -------
# HEAD descends from woven/main, so oidc.ts diverges from the baseline. That is
# exactly the branch someone would cut to upstream a small additive fix.
echo "-- outbound: HEAD carries a FORK-LOCAL CORE PATCH"
run_guard --outbound --head HEAD
expect_rc 1 "policy violation"
expect_names "$OIDC_PATH"

# --- 14. ADDITIVE rows must NOT trip it --------------------------------------
# The fixture that catches a parser reading the wrong column: seed/index.ts and
# build-test.yml also diverge from the baseline, and both are ADDITIVE.
echo "-- outbound: ADDITIVE divergence is not a leak"
grep -qF -- "$SEED_PATH" "$OUT" && bad "outbound named an ADDITIVE file: $SEED_PATH" || ok "ADDITIVE $SEED_PATH not named"
grep -qF -- ".github/workflows/build-test.yml" "$OUT" && bad "outbound named an ADDITIVE file: build-test.yml" || ok "ADDITIVE build-test.yml not named"

# --- 15. outbound refuses to judge an undeclared divergence ------------------
# Not a duplicate of the inbound unmanifested fixture: it pins the ORDERING.
# Deleting oidc.ts's OWN row empties FORKLOCAL along with UNMANIFESTED's
# counterpart, so this covers the empty-FORKLOCAL case: if outbound consulted
# FORKLOCAL first, a manifest row that failed to parse would drop its file out
# of the set and the leak check would pass vacuously.
echo "-- outbound: an unmanifested upstream-owned file is not judgeable"
grep -v -- "providers/oidc.ts" "$MANIFEST" >"$TMPDIR_T/m-nooidc.md"
run_guard --outbound --manifest "$TMPDIR_T/m-nooidc.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$OIDC_PATH"

# --- 15b. ordering, with a REAL leak also present ----------------------------
# 15 alone doesn't pin which check runs FIRST: with oidc.ts's own row gone,
# FORKLOCAL is empty too, so a guard that consulted the leak check before the
# unmanifested one would also see nothing there and still exit 1 — for the
# wrong reason. This fixture removes the ADDITIVE seed/index.ts row instead,
# leaving oidc.ts's FORK-LOCAL row intact, so UNMANIFESTED (seed) and LEAKED
# (oidc) are BOTH non-empty at once. Asserting the "cannot judge" message names
# seed/index.ts, and that the leak message never appears, pins that the
# unmanifested gate ran — and returned — before the leak check could.
echo "-- outbound: an unmanifested file blocks judgement even with a real leak present"
grep -v -- "src/seed/index.ts" "$MANIFEST" >"$TMPDIR_T/m-noseed.md"
run_guard --outbound --manifest "$TMPDIR_T/m-noseed.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$SEED_PATH"
if grep -qF -- "FORK-LOCAL CORE PATCH on an upstream-directed change set" "$OUT"; then
  bad "outbound reported the leak message instead of refusing to judge — ordering broke"
else
  ok "outbound refused to judge before ever reaching the leak check"
fi

# --- 16. a rename hides the fork-local path from a default diff -------------
# git diff has rename detection ON by default and --name-only reports only the
# DESTINATION path. Renaming oidc.ts (FORK-LOCAL CORE PATCH) to a new path with
# byte-identical, already-diverged content used to make the manifested path
# vanish from CHANGED entirely: comm -12 found nothing, and the guard printed
# "no FORK-LOCAL CORE PATCH ... safe to send upstream" while the patch was
# fully present on the branch under a new name. Built with plumbing against a
# scratch index seeded from HEAD, so no branch, index or working tree is
# touched.
#
# A plain "not clean" assertion here cannot tell WHICH fix is doing the work:
# STALE's own tree-presence check (git cat-file, independent of any diff flag)
# already catches oidc.ts's absence on its own, so reverting --no-renames
# alone still exits 1 here, and reverting the STALE gate alone still exits 1
# here too (LEAKED catches it via --no-renames). Verified by hand against
# single-fix mutants of the guard. So this fixture asserts two SEPARATE
# signals, each driven by the guard's own execution, not a re-derivation:
#   (a) the STALE gate specifically ran — the exact "manifest row(s) whose
#       path no longer exists" message, not just any exit-1 message. A guard
#       that dropped the STALE gate would fall through to LEAKED instead and
#       print the FORK-LOCAL leak message here, not this one.
#   (b) --no-renames specifically took effect — the guard's own "N upstream-
#       owned" count in its log line, which is 3 (oidc.ts + seed/index.ts +
#       build-test.yml) only because oidc.ts's OLD path still shows up in
#       CHANGED. Restore rename detection (drop --no-renames, or reintroduce
#       it "for nicer reporting") and oidc.ts vanishes from CHANGED, so this
#       drops to 2 — independent of whatever the STALE gate does.
echo "-- outbound: a rename hides the fork-local path from a default diff"
RENAME_PATH="packages/backend/server/src/plugins/oauth/providers/oidc-provider.ts"
rn_index="$TMPDIR_T/index.rename"
oidc_entry="$(git ls-tree HEAD -- "$OIDC_PATH")"
oidc_mode="$(printf '%s' "$oidc_entry" | awk '{print $1}')"
oidc_blob="$(printf '%s' "$oidc_entry" | awk '{print $3}')"
GIT_INDEX_FILE="$rn_index" git read-tree HEAD
GIT_INDEX_FILE="$rn_index" git update-index --force-remove "$OIDC_PATH"
GIT_INDEX_FILE="$rn_index" git update-index --add --cacheinfo "${oidc_mode},${oidc_blob},${RENAME_PATH}"
rn_tree="$(GIT_INDEX_FILE="$rn_index" git write-tree)"
RN_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
          GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
          git commit-tree "$rn_tree" -p HEAD -m 'outbound rename fixture: oidc.ts -> oidc-provider.ts, identical content')"

if [ -z "$RN_REF" ]; then
  bad "could not build the rename fixture commit"
else
  run_guard --outbound --head "$RN_REF"
  expect_rc 1 "not clean -- either a leak or a refusal to judge a stale row"
  expect_names "$OIDC_PATH"

  # (a) pins the STALE gate: the specific "cannot judge" / stale-row message.
  if grep -qF -- "manifest row(s) whose path no longer exists in the tree" "$OUT"; then
    ok "outbound refused to judge via the STALE gate specifically"
  else
    bad "outbound did not report the STALE-specific message -- the STALE gate may not be running"
    dump
  fi

  # (b) pins --no-renames: the guard's own upstream-owned count, driven by its
  # own CHANGED computation, not a re-derivation of git's behaviour.
  if grep -qF -- "3 upstream-owned" "$OUT"; then
    ok "--no-renames kept the source path ($OIDC_PATH) in the guard's own CHANGED"
  else
    bad "guard's upstream-owned count does not reflect the source path -- --no-renames may be missing"
    dump
  fi
fi

# --- 17. known-good outbound: a branch built FROM the baseline ---------------
# The counter-fixture: a guard that simply always failed would satisfy #13. This
# builds the branch woven-upstream-branch.sh will build — the upstream baseline
# plus one ADDITIVE file, the manifest's own nominated upstream candidate — with
# plumbing, so no branch, index or working tree is touched.
echo "-- outbound: a branch based on the upstream baseline is clean"
OB_FILE=".github/workflows/build-test.yml"
OB_BASE="$(sed -n 's/^UPSTREAM_COMMIT=//p' "$REPO_ROOT/scripts/woven-upstream-baseline" | head -1)"
ob_index="$TMPDIR_T/index.outbound"
ob_mode_blob="$(git ls-tree HEAD -- "$OB_FILE" | awk '{print $1","$3}')"
GIT_INDEX_FILE="$ob_index" git read-tree "$OB_BASE"
GIT_INDEX_FILE="$ob_index" git update-index --add --cacheinfo "${ob_mode_blob},${OB_FILE}"
ob_tree="$(GIT_INDEX_FILE="$ob_index" git write-tree)"
OB_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
          GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
          git commit-tree "$ob_tree" -p "$OB_BASE" -m 'outbound known-good fixture')"

if [ -z "$OB_REF" ]; then
  bad "could not build the known-good outbound fixture commit"
else
  run_guard --outbound --head "$OB_REF"
  expect_rc 0 "clean"

  # rc 0 alone cannot tell "the outbound check ran and cleared this branch" from
  # "no check ran" — deleting the whole --outbound block leaves this fixture
  # green. Assert the guard's OWN success message and its OWN change count. The
  # count also catches the fixture commit degrading to an empty diff, which
  # write-tree/commit-tree absorb silently: if ls-tree finds no OB_FILE, the
  # cacheinfo add fails and the tree stays the pristine baseline.
  if grep -qF -- "1 changed vs baseline · 1 upstream-owned" "$OUT"; then
    ok "the fixture commit really carries exactly one upstream-owned change"
  else
    bad "fixture commit is not the intended baseline+one-ADDITIVE-file branch"; dump
  fi
  if grep -qF -- "no FORK-LOCAL CORE PATCH in this change set" "$OUT"; then
    ok "cleared by the outbound check specifically"
  else
    bad "exit 0 did not come from the outbound clean path"; dump
  fi
fi

# --- 14. fail closed: an unrecognised State is an ENVIRONMENT error ----------
# Same rule as an unrecognised Category. A typo'd REMOVED must not silently read
# as PRESENT — that would turn a declared deletion back into a STALE row, which
# is the deadlock this whole change exists to remove.
echo "-- fail closed: State=REMOVEDD is rejected, not guessed"
awk -v p="$OIDC_PATH" '
  $0 ~ p && /^\|/ { sub(/[[:space:]]*\|[[:space:]]*$/, " | **REMOVEDD** |"); }
  { print }
' "$MANIFEST" >"$TMPDIR_T/m-badstate.md"
run_guard --manifest "$TMPDIR_T/m-badstate.md"
expect_rc 2 "environment error"
expect_names "REMOVEDD"

# --- 15. the deadlock: a fork deletion declared REMOVED reaches green --------
# affine-83p. Before this change both manifest states were red: keeping the row
# gave STALE ("drop the row"), dropping it gave UNMANIFESTED ("add a row"). The
# operator was told to do the thing they had just done.
echo "-- declared deletion: delete oidc.ts, State=REMOVED -> clean"
mark_removed "$OIDC_PATH" "$TMPDIR_T/m-removed.md"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null; then
  bad "$OIDC_PATH already has uncommitted changes; skipping"
else
  trap 'restore_oidc; rm -rf "$TMPDIR_T"' EXIT
  rm -f "$OIDC_PATH"
  run_guard --manifest "$TMPDIR_T/m-removed.md"
  expect_rc 0 "declared deletion is clean"
  restore_oidc
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

# --- 16. RESURRECTED: the row says the fork removes it, but it is back -------
# A safety property the guard did not previously have. An upstream merge that
# restores a file the fork deleted is otherwise completely silent.
echo "-- resurrected: State=REMOVED but the file is present"
mark_removed "$SEED_PATH" "$TMPDIR_T/m-resurrect.md"
run_guard --manifest "$TMPDIR_T/m-resurrect.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$SEED_PATH"

# --- 17. OBSOLETE: upstream deleted it too, so the row describes nothing -----
# A previous version of this fixture hijacked oidc.ts's OWN row (renaming its
# path to the ghost path), which drops oidc.ts out of the manifest and trips
# UNMANIFESTED(oidc.ts) on its own -- rc=1 regardless of whether OBSOLETE is
# even reported. Verified by mutation: `rc=1` -> `:` in the OBSOLETE block
# still left every fixture green. Fixed by ADDING a fourth row instead, so all
# three real rows stay manifested and OBSOLETE is the only thing that can
# fail the guard here.
echo "-- obsolete: State=REMOVED on a path absent from the baseline"
GHOST_REMOVED="packages/backend/server/src/gone-from-both.ts"
awk -v p="$OIDC_PATH" -v ghost="$GHOST_REMOVED" '
  { print }
  $0 ~ p && /^\|/ && !done {
    line = $0
    sub(p, ghost, line)
    print line
    done = 1
  }
' "$MANIFEST" >"$TMPDIR_T/m-obs-1.md"
awk -v p="$GHOST_REMOVED" '
  $0 ~ p && /^\|/ { sub(/[[:space:]]*\|[[:space:]]*$/, " | **REMOVED** |"); }
  { print }
' "$TMPDIR_T/m-obs-1.md" >"$TMPDIR_T/m-obsolete.md"
run_guard --manifest "$TMPDIR_T/m-obsolete.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$GHOST_REMOVED"
if grep -qF -- "UNMANIFESTED" "$OUT"; then
  bad "fixture 17 tripped UNMANIFESTED instead of testing OBSOLETE in isolation"
else
  ok "no UNMANIFESTED noise -- OBSOLETE is the sole reported verdict"
fi

# --- 18. STALE names BOTH causes and both achievable fixes -------------------
# The acceptance criterion of affine-83p: the message must distinguish "absent
# because upstream deleted it" from "absent because this branch deleted it", and
# must not prescribe an action that produces the opposite failure.
echo "-- stale message: offers REMOVED as well as drop/repoint"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null; then
  bad "$OIDC_PATH already has uncommitted changes; skipping"
else
  trap 'restore_oidc; rm -rf "$TMPDIR_T"' EXIT
  rm -f "$OIDC_PATH"
  run_guard   # live manifest: the row is PRESENT and undeclared
  expect_rc 1 "policy violation"
  expect_names "$OIDC_PATH" "REMOVED"
  restore_oidc
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

# --- 19. MOVED: source gone, destination present -> clean --------------------
echo "-- moved: git mv oidc.ts, row State=MOVED <dest> -> clean"
mark_moved "$OIDC_PATH" "$MOVED_DEST" "$TMPDIR_T/m-moved.md"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null; then
  bad "$OIDC_PATH already has uncommitted changes; skipping"
else
  trap 'restore_move; rm -rf "$TMPDIR_T"' EXIT
  git mv "$OIDC_PATH" "$MOVED_DEST"
  run_guard --manifest "$TMPDIR_T/m-moved.md"
  expect_rc 0 "declared rename is clean"

  # --- 20. MOVED with a destination that is not there is a violation ---------
  echo "-- moved: destination absent -> violation"
  mark_moved "$OIDC_PATH" "packages/backend/server/src/never-created.ts" "$TMPDIR_T/m-moved-gone.md"
  run_guard --manifest "$TMPDIR_T/m-moved-gone.md"
  expect_rc 1 "policy violation"
  expect_names "never-created.ts"

  restore_move
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
