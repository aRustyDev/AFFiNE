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
    $0 ~ p && /^\|/ { sub(/\|[[:space:]]*\|[[:space:]]*$/, "| **REMOVED** |"); }
    { print }
  ' "$MANIFEST" >"$2"
}
mark_moved() {  # $1 = source, $2 = destination, $3 = output manifest
  awk -v p="$1" -v dst="$2" '
    $0 ~ p && /^\|/ { sub(/\|[[:space:]]*\|[[:space:]]*$/, "| **MOVED** `" dst "` |"); }
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

# --- 18. fail closed: an unrecognised State is an ENVIRONMENT error ----------
# Same rule as an unrecognised Category. A typo'd REMOVED must not silently read
# as PRESENT — that would turn a declared deletion back into a STALE row, which
# is the deadlock this whole change exists to remove.
echo "-- fail closed: State=REMOVEDD is rejected, not guessed"
awk -v p="$OIDC_PATH" '
  $0 ~ p && /^\|/ { sub(/\|[[:space:]]*\|[[:space:]]*$/, "| **REMOVEDD** |"); }
  { print }
' "$MANIFEST" >"$TMPDIR_T/m-badstate.md"
run_guard --manifest "$TMPDIR_T/m-badstate.md"
expect_rc 2 "environment error"
expect_names "REMOVEDD"

# --- 19. the deadlock: a fork deletion declared REMOVED reaches green --------
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

# --- 20. RESURRECTED: the row says the fork removes it, but it is back -------
# A safety property the guard did not previously have. An upstream merge that
# restores a file the fork deleted is otherwise completely silent.
echo "-- resurrected: State=REMOVED but the file is present"
mark_removed "$SEED_PATH" "$TMPDIR_T/m-resurrect.md"
run_guard --manifest "$TMPDIR_T/m-resurrect.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$SEED_PATH"

# --- 21. OBSOLETE: upstream deleted it too, so the row describes nothing -----
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
  $0 ~ p && /^\|/ { sub(/\|[[:space:]]*\|[[:space:]]*$/, "| **REMOVED** |"); }
  { print }
' "$TMPDIR_T/m-obs-1.md" >"$TMPDIR_T/m-obsolete.md"
run_guard --manifest "$TMPDIR_T/m-obsolete.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$GHOST_REMOVED"
if grep -qF -- "UNMANIFESTED" "$OUT"; then
  bad "fixture 21 tripped UNMANIFESTED instead of testing OBSOLETE in isolation"
else
  ok "no UNMANIFESTED noise -- OBSOLETE is the sole reported verdict"
fi

# --- 22. STALE names BOTH causes and both achievable fixes -------------------
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

# --- 23. MOVED: source gone, destination present -> clean --------------------
# The precondition check must catch a STRANDED tree too, not just an ordinary
# dirty one: `git mv` stages both halves of the rename, so if a PRIOR run of
# this fixture was killed after `git mv` but before restore_move(), the index
# no longer has an entry at $OIDC_PATH at all -- there is nothing left for a
# plain `git diff --quiet -- "$OIDC_PATH"` (working tree vs INDEX) to compare,
# so it reports "quiet" even though the tree is not actually in its starting
# state. Requiring the source to literally exist closes that gap directly.
echo "-- moved: git mv oidc.ts, row State=MOVED <dest> -> clean"
mark_moved "$OIDC_PATH" "$MOVED_DEST" "$TMPDIR_T/m-moved.md"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null || [ ! -e "$OIDC_PATH" ]; then
  bad "$OIDC_PATH already has uncommitted changes, or is missing (a prior interrupted run?); skipping"
else
  trap 'restore_move; rm -rf "$TMPDIR_T"' EXIT
  # set -uo pipefail has no -e, so a failed `git mv` would otherwise be
  # silently ignored and every fixture below would run against whatever state
  # the failed move left behind -- hard-fail instead of guessing.
  if ! git mv "$OIDC_PATH" "$MOVED_DEST"; then
    bad "git mv $OIDC_PATH -> $MOVED_DEST failed; skipping fixtures 23-25 rather than continuing on an unknown tree state"
  else
    run_guard --manifest "$TMPDIR_T/m-moved.md"
    expect_rc 0 "declared rename is clean"

    # --- 24. MOVED with a destination that is not there is a violation -------
    echo "-- moved: destination absent -> violation"
    mark_moved "$OIDC_PATH" "packages/backend/server/src/never-created.ts" "$TMPDIR_T/m-moved-gone.md"
    run_guard --manifest "$TMPDIR_T/m-moved-gone.md"
    expect_rc 1 "policy violation"
    expect_names "never-created.ts"

    # --- 25. MOVED destination that is a DIRECTORY is a violation, not clean -
    # A directory satisfies both `[ -e ]` (worktree mode) and `git cat-file -e`
    # (committed mode) -- a MOVED row typo'd to name the file's own parent
    # directory would otherwise read as "destination present" and fail open,
    # which is exactly the error class this whole check exists to catch.
    echo "-- moved: destination is a directory, not a file -> violation"
    DIR_DEST="packages/backend/server/src/plugins/oauth/providers"
    mark_moved "$OIDC_PATH" "$DIR_DEST" "$TMPDIR_T/m-moved-dir.md"
    run_guard --manifest "$TMPDIR_T/m-moved-dir.md"
    expect_rc 1 "policy violation"
    expect_names "$DIR_DEST"
  fi

  restore_move
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

# --- 26. clause 3: outbound sees a FORK-LOCAL patch at its NEW address -------
# Without this, fixing the deadlock reintroduces the very leak --no-renames
# exists to prevent: the rename reaches green, the destination is fork-owned
# (absent at the baseline) and so falls outside UPSTREAM_OWNED, and outbound
# goes blind to a fully-present relocated core patch. This fixture is the only
# thing standing between the affine-83p fix and that regression.
#
# Same hardened precondition as fixtures 23-25: require the source to
# literally exist (not just `git diff --quiet`, which a tree stranded by a
# prior interrupted run would pass vacuously), and hard-fail if `git mv`
# itself fails rather than continuing on an unknown tree state.
echo "-- outbound: a MOVED FORK-LOCAL patch is caught at its destination"
mark_moved "$OIDC_PATH" "$MOVED_DEST" "$TMPDIR_T/m-moved.md"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null || [ ! -e "$OIDC_PATH" ]; then
  bad "$OIDC_PATH already has uncommitted changes, or is missing (a prior interrupted run?); skipping"
else
  trap 'restore_move; rm -rf "$TMPDIR_T"' EXIT
  if ! git mv "$OIDC_PATH" "$MOVED_DEST"; then
    bad "git mv $OIDC_PATH -> $MOVED_DEST failed; skipping fixture 26 rather than continuing on an unknown tree state"
  else
    run_guard --outbound --manifest "$TMPDIR_T/m-moved.md"
    expect_rc 1 "policy violation"
    expect_names "$MOVED_DEST"
  fi
  restore_move
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

# --- 27. the realistic exploit shape: an upstream-directed branch built ------
#         FROM the baseline that only ADDS the relocated FORK-LOCAL file ------
# Fixture 26 renames on top of the current branch (git mv, so the source is
# genuinely GONE from the resulting tree) -- that isolates clause 3 cleanly,
# which is why fixture 26 is the one mutation-tested against clause 3 alone.
# This fixture instead reproduces the shape a reviewer actually used to
# demonstrate the leak end to end: a branch cut FROM the upstream baseline --
# the shape scripts/woven-upstream-branch.sh builds, same as fixture 17 -- that
# never touches the source path at all. It only ADDS the fork-local file's
# CONTENT at its NEW, fork-owned address, so the source path stays
# byte-identical to the baseline and never appears in CHANGED: UPSTREAM_OWNED
# is 0, and originally -- before the outbound pre-gate was extended to consult
# every inbound verdict, not just UNMANIFESTED/STALE (see the INBOUND_UNCLEAN
# comment above OUTBOUND mode) -- LEAKED (comm -12 CHANGED FORKLOCAL) was empty
# too, so the guard printed "no FORK-LOCAL CORE PATCH ... safe to send
# upstream" at rc 0: a full, undegraded pass.
#
# A DIRECT CONSEQUENCE OF THAT SAME FIX: this shape's source path is left
# untouched -- present, byte-identical to baseline -- and RESURRECTED checks
# presence, not content, so a MOVED row whose source is merely left alone (as
# it always will be in this exact shape) now trips RESURRECTED before LEAKED
# ever runs. That is correct and desirable: from presence alone the guard
# cannot tell an untouched baseline copy from the fork's own patch sitting
# where the row says it shouldn't. But it means this fixture no longer
# isolates clause 3 the way it did when first written -- rc 1 now comes from
# RESURRECTED, not from LEAKED naming the destination. Fixture 26 carries the
# clause-3-isolation burden now (see its own mutation test); this fixture's
# job is narrower -- pin that the realistic add-only shape stays blocked, by
# WHATEVER inbound verdict catches it, and that the block is a refusal to
# judge, not a leak verdict standing in by coincidence. Built with plumbing
# against a scratch index seeded from the baseline, exactly like fixture 17,
# so no branch, index or working tree is touched -- no git-mv, so none of the
# stranded-tree hazard fixtures 23-26 have to guard against.
echo "-- outbound: an upstream-baseline branch that only ADDS the relocated FORK-LOCAL file"
mark_moved "$OIDC_PATH" "$MOVED_DEST" "$TMPDIR_T/m-moved-addonly.md"
addonly_index="$TMPDIR_T/index.addonly"
oidc_entry_ao="$(git ls-tree HEAD -- "$OIDC_PATH")"
oidc_mode_ao="$(printf '%s' "$oidc_entry_ao" | awk '{print $1}')"
oidc_blob_ao="$(printf '%s' "$oidc_entry_ao" | awk '{print $3}')"
GIT_INDEX_FILE="$addonly_index" git read-tree "$OB_BASE"
GIT_INDEX_FILE="$addonly_index" git update-index --add --cacheinfo "${oidc_mode_ao},${oidc_blob_ao},${MOVED_DEST}"
addonly_tree="$(GIT_INDEX_FILE="$addonly_index" git write-tree)"
ADDONLY_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
               GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
               git commit-tree "$addonly_tree" -p "$OB_BASE" -m 'outbound add-only relocation fixture: FORK-LOCAL content lands only at the MOVED destination')"

if [ -z "$ADDONLY_REF" ]; then
  bad "could not build the add-only relocation fixture commit"
else
  run_guard --outbound --base "$OB_BASE" --head "$ADDONLY_REF" --manifest "$TMPDIR_T/m-moved-addonly.md"
  expect_rc 1 "policy violation"
  # RESURRECTED fires here (source present, MOVED declared -- see the comment
  # above), so the refusal names the SOURCE path, not the destination.
  expect_names "$OIDC_PATH"
  if grep -qF -- "cannot judge this change set" "$OUT"; then
    ok "blocked by a refusal to judge, not a leak verdict"
  else
    bad "expected a pre-gate refusal to judge, not whatever this is"; dump
  fi

  # Pin the SHAPE, not just the outcome: this must be the degenerate
  # "0 upstream-owned" case the reviewer demonstrated, not some other reason
  # the guard happens to fail -- otherwise a guard that just always failed
  # here would satisfy the fixture without clause 3 doing anything.
  if grep -qF -- "1 changed vs baseline · 0 upstream-owned" "$OUT"; then
    ok "fixture commit really is baseline + one fork-owned addition (0 upstream-owned)"
  else
    bad "fixture commit does not match the intended add-only shape"; dump
  fi
fi

# --- 28. the reviewer's exploit: a MOVED destination that does not match -----
#         where the FORK-LOCAL content actually landed ------------------------
# The defect a code review found in the affine-83p follow-up: outbound's
# pre-gate consulted UNMANIFESTED and STALE, but never MOVED_GONE (or
# RESURRECTED, or OBSOLETE). So a MOVED row whose declared destination is
# wrong -- a typo, a stale edit, a row nobody re-verified after the file
# actually landed -- let clause 3 add the DECLARED (wrong) path to FORKLOCAL.
# That path is not in CHANGED (nothing was ever written there), so LEAKED came
# out empty and outbound printed "safe to send upstream" at rc 0 while the
# patch was fully present under its REAL name. Inbound, over the same
# manifest, correctly reported MOVED_GONE. The two directions disagreed --
# exactly what .claude/plans/upstream-leak-guard/DESIGN.md says must be
# impossible by construction.
#
# Same add-only-from-baseline plumbing as fixture 27 (content lands only at
# the REAL destination, source untouched), but the manifest's MOVED cell names
# a ONE-CHARACTER-TYPO'd destination that was never written anywhere -- the
# reviewer's own reproduction. Because the source is untouched here too (same
# reason as fixture 27), RESURRECTED fires as well; the assertion that matters
# is MOVED_GONE specifically naming the WRONG (declared) destination, since
# that is the exact verdict this defect skipped over, and that no leak-verdict
# message appears -- a refusal to judge, not a leak report that happens to
# also block it.
echo "-- outbound: a MOVED destination that does not match where the content actually landed"
TYPO_DEST="packages/backend/server/src/plugins/oauth/providers/woven-0idc.ts"
mark_moved "$OIDC_PATH" "$TYPO_DEST" "$TMPDIR_T/m-moved-typo.md"
typo_index="$TMPDIR_T/index.typo"
oidc_entry_typo="$(git ls-tree HEAD -- "$OIDC_PATH")"
oidc_mode_typo="$(printf '%s' "$oidc_entry_typo" | awk '{print $1}')"
oidc_blob_typo="$(printf '%s' "$oidc_entry_typo" | awk '{print $3}')"
GIT_INDEX_FILE="$typo_index" git read-tree "$OB_BASE"
# The content lands at the REAL destination ($MOVED_DEST) -- the manifest cell
# below names a DIFFERENT (typo'd) path, so the two never match.
GIT_INDEX_FILE="$typo_index" git update-index --add --cacheinfo "${oidc_mode_typo},${oidc_blob_typo},${MOVED_DEST}"
typo_tree="$(GIT_INDEX_FILE="$typo_index" git write-tree)"
TYPO_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
            GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
            git commit-tree "$typo_tree" -p "$OB_BASE" -m 'outbound typo-destination fixture: manifest MOVED cell does not match where the content actually landed')"

if [ -z "$TYPO_REF" ]; then
  bad "could not build the typo-destination fixture commit"
else
  run_guard --outbound --base "$OB_BASE" --head "$TYPO_REF" --manifest "$TMPDIR_T/m-moved-typo.md"
  expect_rc 1 "policy violation"
  # Pins MOVED_GONE specifically: the declared (wrong) destination is named,
  # proving the pre-gate is reading MOVED_GONE now, not just RESURRECTED.
  expect_names "$TYPO_DEST"
  if grep -qF -- "FORK-LOCAL CORE PATCH on an upstream-directed change set" "$OUT"; then
    bad "outbound reported a LEAK verdict instead of refusing to judge -- the pre-gate is not consulting MOVED_GONE"
  else
    ok "blocked by a refusal to judge, not a leak verdict standing in by coincidence"
  fi
fi

# --- 29. a REMOVED FORK-LOCAL row still cannot go upstream -------------------
# affine-83p's central bet: State is ORTHOGONAL to Category, so deletion
# inherits its row's upstreamability rather than needing a policy of its own.
# This fixture is the FORK-LOCAL half of that bet. A branch cut from the
# upstream baseline (the shape woven-upstream-branch.sh builds, same as
# fixtures 17/27/28) whose ONLY change is to DELETE oidc.ts, with the
# manifest's oidc.ts row marked REMOVED so inbound is fully clean over it —
# RESURRECTED and OBSOLETE both require the path to be either present or
# absent-at-baseline-too, neither of which holds here. A REMOVED row still
# contributes its path to FORKLOCAL unconditionally (the classifier ignores
# State when building that set — see the FORKLOCAL awk above), so the
# deletion still lands in LEAKED. Built with the same scratch-index plumbing
# as fixture 17: read-tree the baseline, THEN force-remove the one path,
# write-tree, commit-tree with the baseline as parent — no branch, index or
# working tree touched, so none of the stranded-tree hazard fixtures 23-26
# guard against applies here either.
echo "-- outbound: a REMOVED FORK-LOCAL row still cannot go upstream"
mark_removed "$OIDC_PATH" "$TMPDIR_T/m-removed-oidc-ob.md"
rm29_index="$TMPDIR_T/index.rm29"
GIT_INDEX_FILE="$rm29_index" git read-tree "$OB_BASE"
GIT_INDEX_FILE="$rm29_index" git update-index --force-remove "$OIDC_PATH"
rm29_tree="$(GIT_INDEX_FILE="$rm29_index" git write-tree)"
RM29_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
            GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
            git commit-tree "$rm29_tree" -p "$OB_BASE" -m 'outbound REMOVED fork-local fixture: delete oidc.ts')"

if [ -z "$RM29_REF" ]; then
  bad "could not build the REMOVED-fork-local fixture commit"
else
  run_guard --outbound --base "$OB_BASE" --head "$RM29_REF" --manifest "$TMPDIR_T/m-removed-oidc-ob.md"
  expect_rc 1 "policy violation"
  expect_names "$OIDC_PATH"

  # Discriminating: rc 1 must come from the LEAK check specifically (deletion
  # still counts as FORK-LOCAL), not from some unrelated pre-gate refusal that
  # would pass this fixture for the wrong reason.
  if grep -qF -- "FORK-LOCAL CORE PATCH on an upstream-directed change set" "$OUT"; then
    ok "blocked by the leak verdict specifically -- deletion still counts as FORK-LOCAL"
  else
    bad "expected a LEAK verdict naming the deleted FORK-LOCAL row, not whatever this is"; dump
  fi
  if grep -qF -- "cannot judge this change set" "$OUT"; then
    bad "outbound refused to judge instead of reaching the leak check -- fixture is not isolating deletion"
  else
    ok "outbound reached the leak check (inbound was fully clean over the REMOVED row)"
  fi

  # Shape: exactly one change vs baseline, that one change IS upstream-owned
  # (oidc.ts existed at the baseline), and the manifest's row count is
  # unaffected by mark_removed (still 3 rows) -- pins this as the intended
  # baseline-minus-one-FORK-LOCAL-file shape, not some other reason to fail.
  if grep -qF -- "1 changed vs baseline · 1 upstream-owned · 3 manifest row(s)" "$OUT"; then
    ok "fixture commit really is baseline minus the one FORK-LOCAL file (1 upstream-owned, 3 rows)"
  else
    bad "fixture commit does not match the intended REMOVED-FORK-LOCAL shape"; dump
  fi
fi

# --- 30. a REMOVED ADDITIVE row IS sendable upstream --------------------------
# The ADDITIVE half of the same bet, and the contrast that actually proves it:
# if deletion were treated as categorically un-sendable (a hypothetical third
# "FORK-LOCAL DELETION" bucket, or a blanket "any REMOVED row blocks outbound"
# rule) this fixture would fail. Same construction as #29 but deleting
# seed/index.ts (an ADDITIVE row) instead, with THAT row marked REMOVED.
# oidc.ts is never touched by this fixture, so it stays byte-identical to the
# baseline and never enters CHANGED -- asserted explicitly below, not just
# assumed, since a stray touch of oidc.ts would make this fixture pass for the
# wrong reason (or fail outright).
echo "-- outbound: a REMOVED ADDITIVE row IS sendable upstream"
mark_removed "$SEED_PATH" "$TMPDIR_T/m-removed-seed-ob.md"
rm30_index="$TMPDIR_T/index.rm30"
GIT_INDEX_FILE="$rm30_index" git read-tree "$OB_BASE"
GIT_INDEX_FILE="$rm30_index" git update-index --force-remove "$SEED_PATH"
rm30_tree="$(GIT_INDEX_FILE="$rm30_index" git write-tree)"
RM30_REF="$(GIT_AUTHOR_NAME='woven-guard-fixture'    GIT_AUTHOR_EMAIL='fixture@woven.invalid' \
            GIT_COMMITTER_NAME='woven-guard-fixture' GIT_COMMITTER_EMAIL='fixture@woven.invalid' \
            git commit-tree "$rm30_tree" -p "$OB_BASE" -m 'outbound REMOVED additive fixture: delete seed/index.ts')"

if [ -z "$RM30_REF" ]; then
  bad "could not build the REMOVED-additive fixture commit"
else
  run_guard --outbound --base "$OB_BASE" --head "$RM30_REF" --manifest "$TMPDIR_T/m-removed-seed-ob.md"
  expect_rc 0 "clean -- deletion of an ADDITIVE row is sendable"

  # Shape: exactly one change vs baseline, that one change IS upstream-owned
  # (seed/index.ts existed at the baseline) -- rules out the degenerate "empty
  # diff" failure mode write-tree/commit-tree would otherwise absorb silently.
  if grep -qF -- "1 changed vs baseline · 1 upstream-owned · 3 manifest row(s)" "$OUT"; then
    ok "fixture commit really is baseline minus the one ADDITIVE file (1 upstream-owned, 3 rows)"
  else
    bad "fixture commit does not match the intended REMOVED-ADDITIVE shape"; dump
  fi
  if grep -qF -- "no FORK-LOCAL CORE PATCH in this change set" "$OUT"; then
    ok "cleared by the outbound check specifically"
  else
    bad "exit 0 did not come from the outbound clean path"; dump
  fi
  if grep -qF -- "$OIDC_PATH" "$OUT"; then
    bad "oidc.ts appeared in the output -- it should never have entered CHANGED for this fixture"
  else
    ok "oidc.ts never entered CHANGED (left byte-identical to the baseline)"
  fi
fi

# --- 31. a manifest with NO State column still parses as all-PRESENT ---------
# The migration guarantee: State is appended, absent means PRESENT, and PRESENT
# is the pre-affine-83p behaviour. Built by hand at four columns so it cannot
# drift when the live manifest gains its fifth.
echo "-- compat: four-column manifest behaves exactly as before"
{
  echo '## Diverged upstream-owned files'
  echo
  echo '| File | Category | Why | Delete when |'
  echo '| ---- | -------- | --- | ----------- |'
  echo "| \`$OIDC_PATH\` | **FORK-LOCAL CORE PATCH** | x | y |"
  echo "| \`$SEED_PATH\` | **ADDITIVE** | x | y |"
  echo '| `.github/workflows/build-test.yml` | **ADDITIVE** | x | y |'
} >"$TMPDIR_T/m-fourcol.md"
run_guard --manifest "$TMPDIR_T/m-fourcol.md" --head HEAD
expect_rc 0 "four-column manifest is clean"

# expect_rc 0 alone is weak: it would also pass if the hand-built manifest
# silently failed to parse and produced zero rows (an empty MANIFESTED list is
# only a WARNING inbound, not a failure -- see check 1 above), or if the three
# rows were misread into the wrong category. Pin the SHAPE too, the same way
# fixtures #12 and #17 do: the guard's own row count, and --dump-rows's actual
# per-row classification.
if grep -qF -- "3 manifest row(s)" "$OUT"; then
  ok "four-column manifest parsed all 3 rows, not silently zero"
else
  bad "guard did not report 3 manifest rows for the four-column manifest"; dump
fi

run_guard --dump-rows --manifest "$TMPDIR_T/m-fourcol.md"
expect_rc 0 "dump-rows on the four-column manifest"
FOURCOL_DUMP="$(grep -F "$(printf '\t')" "$OUT" | sort)"
EXPECT_FOURCOL_DUMP="$(printf '%s\n' \
  "$OIDC_PATH"$'\t'"FORK-LOCAL CORE PATCH"$'\t'"PRESENT"$'\t' \
  ".github/workflows/build-test.yml"$'\t'"ADDITIVE"$'\t'"PRESENT"$'\t' \
  "$SEED_PATH"$'\t'"ADDITIVE"$'\t'"PRESENT"$'\t' | sort)"
if [ "$FOURCOL_DUMP" = "$EXPECT_FOURCOL_DUMP" ]; then
  ok "dump-rows shows all 3 rows as PRESENT with an empty destination -- the absent fifth column defaults correctly"
else
  bad "dump-rows output for the four-column manifest does not match the expected all-PRESENT pairing"
  dump
fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
