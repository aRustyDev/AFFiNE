#!/usr/bin/env bash
#
# woven-drift-sweep.test.sh — the v0.27.4 dry-run, frozen.
#
# affine-3os mandates a plan-drift sweep after every upstream merge. For the
# v0.27.4 merge (eac15e21bd) it did not run, and a hand audit on 2026-08-29
# found drift that had been sitting unflagged — notably affine-yiz (analysis
# invalidated by the merge) and affine-4aj (half-fixed by an incidental commit).
#
# This suite is bead affine-hn1.3's acceptance test: replaying the sweep over
# the v0.27.4 divergence MUST surface those two. If it would not have caught
# them, the procedure is not finished.
#
# The bead corpus is FROZEN at scripts/fixtures/woven-drift-sweep.v0.27.4.json
# so the proof does not rot when those beads close. Its `notes` are deliberately
# BLANKED: the notes are the 2026-08-29 audit write-up itself, so matching
# against them would be circular. Title + description + acceptance_criteria are
# the pre-merge text, which is the only fair input.
#
# Usage: scripts/woven-drift-sweep.test.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SWEEP="$REPO_ROOT/scripts/woven-drift-sweep.sh"
FIXTURE="$REPO_ROOT/scripts/fixtures/woven-drift-sweep.v0.27.4.json"

[ -x "$SWEEP" ]   || { echo "FATAL: $SWEEP missing or not executable" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "FATAL: $FIXTURE missing" >&2; exit 2; }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

PASS=0; FAIL=0
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
ok()  { printf '%s\n' "${c_grn}  ✔${c_rst} $*"; PASS=$((PASS+1)); }
bad() { printf '%s\n' "${c_red}  ✗${c_rst} $*" >&2; FAIL=$((FAIL+1)); }

OUT=""; RC=0; N=0
run_sweep() { N=$((N+1)); OUT="$TMPDIR_T/out.$N.txt"; "$SWEEP" "$@" >"$OUT" 2>&1; RC=$?; }
dump()      { sed 's/^/     | /' "$OUT" >&2; }

expect_rc()      { if [ "$RC" -eq "$1" ]; then ok "exit $1${2:+ ($2)}"; else bad "exit $RC; expected $1${2:+ ($2)}"; dump; fi; }
expect_names()   { local s; for s in "$@"; do if grep -qF -- "$s" "$OUT"; then ok "surfaces $s"; else bad "does not surface $s"; dump; fi; done; }
expect_silent()  { local s; for s in "$@"; do if grep -qF -- "$s" "$OUT"; then bad "false positive: $s"; dump; else ok "suppresses $s"; fi; done; }

echo "== woven-drift-sweep: v0.27.4 dry-run =="

# --- 1. the two beads the 2026-08-29 hand audit found ------------------------
echo "-- replay: sweep over v0.27.4..HEAD"
run_sweep --beads "$FIXTURE"
expect_rc 0 "advisory, never blocks"
expect_names "affine-yiz" "affine-4aj"

# --- 2. generic basenames must not drag in unrelated beads -------------------
# affine-1vt.1 and affine-bg2 mention only the bare word "index.ts"; the changed
# file is packages/backend/server/src/seed/index.ts. Matching that basename
# would make the sweep noise, and a noisy sweep stops being run.
echo "-- precision: generic basenames do not match"
expect_silent "affine-1vt.1" "affine-bg2"

# --- 3. a true full-path citation still matches ------------------------------
# affine-hn1.2 cites packages/backend/server/src/seed/index.ts in full.
echo "-- recall: full-path citations still match"
expect_names "affine-hn1.2"

# --- 4. the three drift classes are printed, so this is a checklist ----------
# affine-hn1.3 AC2: the step must name what to look for, not just list beads.
echo "-- the three drift classes are named in the output"
expect_names "SATISFIED" "INVALIDATED" "INCIDENTAL"

# --- 4b. the report is not garbled by stray carriage returns ----------------
# Some jq builds emit CRLF; an unstripped \r returns the cursor mid-line, so a
# candidate silently overwrites the one above it.
echo "-- report carries no stray CR"
if grep -q $'\r' "$OUT"; then bad "output contains a carriage return"; dump; else ok "no CR in output"; fi

# --- 5. usage errors are loud ------------------------------------------------
echo "-- missing bead corpus is an environment error"
run_sweep --beads "$TMPDIR_T/nope.json"
expect_rc 2 "environment error"

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
