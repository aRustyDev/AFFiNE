# Upstream Leak Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a FORK-LOCAL CORE PATCH from reaching `toeverything/AFFiNE`, by making the manifest's category column enforceable at three points: branch creation, push, and CI.

**Architecture:** One engine — `scripts/woven-manifest-guard.sh` gains an `--outbound` mode that reads column 2 of the manifest table (already present, currently read by nothing) and fails when a change set touches a file marked FORK-LOCAL CORE PATCH. Three thin callers use it: a branch-prep script that builds an upstream-bound branch from `UPSTREAM_COMMIT` instead of `woven/main`, a `pre-push` hook keyed on the destination URL, and a new CI trigger on `upstream/**`.

**Tech Stack:** POSIX `sh` / `bash`, `awk`, git plumbing (`read-tree`, `update-index`, `commit-tree`), GitHub Actions, husky v9.

**Design:** `.claude/plans/upstream-leak-guard/DESIGN.md`

---

## Before you start

Run every command from the repository root.

Everything this plan adds is pure `bash` / `sh` and runs with no toolchain beyond git — deliberately, since `.husky/pre-push` has to work in a checkout where nothing is installed. Markdown formatting is handled by the pre-commit hook (`lint-staged` runs `oxfmt` over staged files), so it needs no step of its own.

One repo-specific trap: **a new script must carry the executable bit in git, or CI cannot run it.** Adding a file does not always preserve the filesystem mode, so set it explicitly and verify it landed:

```bash
git update-index --chmod=+x scripts/<name>.sh
git ls-files -s scripts/<name>.sh   # must start 100755
```

## File Structure

**Modified:**

- `scripts/woven-manifest-guard.sh` — gains `--outbound`; `manifest_rows()` starts emitting the category. The one place that decides "is this a leak".
- `scripts/woven-manifest-guard.test.sh` — outbound fixtures alongside the existing 13 inbound ones.
- `scripts/woven-upstream-baseline` — gains `UPSTREAM_REPO`, so upstream's identity has one home next to its commit.
- `.github/workflows/woven-manifest-guard.yml` — adds the `push: upstream/**` trigger and an outbound job.
- `scripts/woven-patch-manifest.md` — merge-time checklist gains the outbound rule.
- `scripts/woven-agent-bootstrap.md` — §7 documents how to prepare an upstream contribution.

**Created:**

- `scripts/woven-upstream-branch.sh` — builds a clean upstream-bound branch. Calls the guard; contains no policy of its own.
- `scripts/woven-upstream-branch.test.sh` — fixtures for the above.
- `.husky/pre-push` — refuses a push whose destination is upstream. Pure `sh`, no node.
- `scripts/woven-pre-push.test.sh` — invokes the hook directly with synthetic remote URLs.

**Boundary:** all policy lives in `woven-manifest-guard.sh`. The other three files ask it a question and act on the exit code. No second copy of the manifest parser anywhere.

---

### Task 1: Accept the `--outbound` flag

**Files:**

- Modify: `scripts/woven-manifest-guard.sh:50-66` (args block), `:31-33` (usage comment)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Record the current baseline**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `== 13 passed, 0 failed ==`

Every later task re-runs this. If it is not 13/13 before you start, stop and find out why.

- [ ] **Step 2: Write the failing test**

Append to `scripts/woven-manifest-guard.test.sh`, immediately before the final `echo` / summary block:

```bash
echo "== woven-manifest-guard OUTBOUND fixtures =="

# --- 7. the flag exists ------------------------------------------------------
# Asserts the flag is ACCEPTED — not a usage error — rather than asserting a
# specific clean/violation result. Task 3 makes `--outbound --head HEAD` exit 1,
# because HEAD descends from woven/main and carries oidc.ts. A fixture asserting
# rc 0 here would have to be inverted then, and a green "outbound says clean on
# woven/main" is exactly the pressure that produces the mistake this plan's notes
# warn against. Phrased this way it survives task 3 untouched.
echo "-- outbound: --outbound is accepted"
run_guard --outbound --head HEAD
if [ "$RC" -ne 2 ]; then ok "--outbound accepted (exit $RC, not a usage error)"
else bad "--outbound rejected as a usage error"; dump; fi
```

Inline `if` / `ok` / `bad` is this file's existing idiom for assertions `expect_rc` does not cover — see the worktree-victim fixture and the `FIXTURE_REF` guard.

- [ ] **Step 3: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh 2>&1 | tail -5`
Expected: FAIL — `--outbound rejected as a usage error`, because the args loop hits `*) die "unknown argument: $1"` and exits 2.

- [ ] **Step 4: Add the flag**

In `scripts/woven-manifest-guard.sh`, add to the variable block above the `while` loop (after `HEAD_EXPLICIT=0`):

```bash
OUTBOUND=0
```

Add this case to the args loop, immediately before the `-h|--help` line:

```bash
    --outbound) OUTBOUND=1; shift ;;
```

- [ ] **Step 5: Document it in the usage header**

In the comment block at the top of the file, replace the `# Usage:` line and the line under it with:

```bash
# Usage:
#   scripts/woven-manifest-guard.sh [--base REF] [--head REF] [--manifest PATH]
#   scripts/woven-manifest-guard.sh --outbound [--base REF] [--head REF] [--manifest PATH]
#
# INBOUND (default): fail when an upstream-owned file diverges with no manifest
# row — don't silently lose a fork patch to the next upstream merge.
# OUTBOUND (--outbound): fail when the change set touches a file whose manifest
# row says FORK-LOCAL CORE PATCH — don't leak a fork patch to upstream.
```

- [ ] **Step 6: Stop the `--help` range from being a hardcoded line number**

`-h|--help` runs `sed -n '2,37p' "${BASH_SOURCE[0]}"`. Step 5 made the header longer, so that range now truncates the output mid-sentence.

Do not just bump the number. It is a hardcoded line count that silently truncates whenever the header changes length, it has now been wrong once, and Task 6 would copy the idiom into a new script. Derive the end of the comment block instead:

```bash
    -h|--help)  awk 'NR>1 && !/^#/{exit} NR>1' "${BASH_SOURCE[0]}"; exit 0 ;;
```

`awk` is already used by `manifest_rows()`, so this adds no dependency. Verify:

```bash
scripts/woven-manifest-guard.sh --help | head -2
scripts/woven-manifest-guard.sh --help | tail -3
```

Expected: starts at the line after the shebang, and ends with the `fetch-depth: 0` note — not cut off mid-sentence.

- [ ] **Step 7: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `== 14 passed, 0 failed ==`

- [ ] **Step 8: Commit**

```bash
git add scripts/woven-manifest-guard.sh scripts/woven-manifest-guard.test.sh
git commit -m "feat(woven): accept --outbound in the manifest guard (affine-hn1.4)

The flag is parsed and documented but does nothing yet, so the inbound
behaviour is provably unchanged: 14/14 with the existing 13 assertions intact."
```

---

### Task 2: Parse the category column, fail closed on anything unrecognised

**Files:**

- Modify: `scripts/woven-manifest-guard.sh:106-118` (`manifest_rows` and its consumer)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the failing test**

Append to `scripts/woven-manifest-guard.test.sh`, before the summary block:

```bash
# --- 8. fail closed: an unrecognised category is an ENVIRONMENT error --------
# Never "assume ADDITIVE". A typo in column 2 must not silently open the gate —
# that is the one parsing bug that would be both invisible and catastrophic.
echo "-- fail closed: garbage category exits 2, not 0 or 1"
sed 's|\*\*FORK-LOCAL CORE PATCH\*\*|**FORK LOCAL CORE PATCH**|' "$MANIFEST" >"$TMPDIR_T/m-badcat.md"
run_guard --outbound --manifest "$TMPDIR_T/m-badcat.md" --head HEAD
expect_rc 2 "environment error"
expect_names "$OIDC_PATH"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh 2>&1 | tail -6`
Expected: FAIL — `exit 0; expected 2 (environment error)`. Nothing reads the category yet, so a mangled one is invisible.

- [ ] **Step 3: Emit the category from the parser**

Replace `manifest_rows()` in `scripts/woven-manifest-guard.sh` with:

```bash
manifest_rows() {
  awk '
    /^##[[:space:]]+Diverged upstream-owned files/ { insec = 1; next }
    insec && /^#+[[:space:]]/                      { insec = 0 }
    insec && /^[[:space:]]*\|/ {
      n = split($0, f, "|")
      if (n < 3) next
      if (!match(f[2], /`[^`]+`/)) next
      path = substr(f[2], RSTART + 1, RLENGTH - 2)
      cat = f[3]
      gsub(/[*`]/, "", cat)                 # drop markdown emphasis
      sub(/^[[:space:]]+/, "", cat)
      sub(/[[:space:]]+$/, "", cat)
      print path "\t" cat
    }
  ' "$MANIFEST"
}
```

Two changes from the original: `n < 3` (a row must have a category column at all) and the tab-joined output. The section scoping and the backticked-path requirement in column 1 are untouched — they are what keep the legend table and the measured-justification table out.

- [ ] **Step 4: Keep the inbound consumer working**

Replace the `MANIFESTED=` line directly below the function with:

```bash
MANIFESTED="$(manifest_rows | cut -f1 | sed 's#^\./##' | sed '/^$/d' | sort -u)"
```

- [ ] **Step 5: Classify the rows and reject unknown categories**

Insert immediately after the `MANIFESTED=` line and its `[ -n "$MANIFESTED" ] || warn ...` line:

```bash
# ---- classify the manifest rows by category --------------------------------
# Column 2 is the FORK-LOCAL CORE PATCH / ADDITIVE distinction from affine-cm9.
# An unrecognised value exits 2 in BOTH directions: it is a broken manifest, not
# a policy violation, and guessing "probably additive" is how a leak ships.
FORKLOCAL=""
BADCAT=""
while IFS="$(printf '\t')" read -r p c; do
  [ -n "$p" ] || continue
  case "$c" in
    "FORK-LOCAL CORE PATCH") FORKLOCAL="${FORKLOCAL}${p}"$'\n' ;;
    "ADDITIVE")              : ;;
    *)                       BADCAT="${BADCAT}${p}  [category: ${c:-<empty>}]"$'\n' ;;
  esac
done <<< "$(manifest_rows | sed 's#^\./##')"

if [ -n "$BADCAT" ]; then
  err "manifest row(s) with an unrecognised category — refusing to guess:"
  while IFS= read -r l; do [ -n "$l" ] && err "    $l"; done <<< "$BADCAT"
  err "  Column 2 must be exactly **ADDITIVE** or **FORK-LOCAL CORE PATCH**."
  exit 2
fi
FORKLOCAL="$(printf '%s' "$FORKLOCAL" | sed '/^$/d' | sort -u)"
```

- [ ] **Step 6: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `== 16 passed, 0 failed ==` — the two new assertions plus the original 13 and Task 1's, all still green. The inbound assertions passing is the proof that the shared parser change did not alter inbound behaviour.

- [ ] **Step 7: Commit**

```bash
git add scripts/woven-manifest-guard.sh scripts/woven-manifest-guard.test.sh
git commit -m "feat(woven): read the manifest category column, fail closed (affine-hn1.4)

manifest_rows() now emits path<TAB>category and the inbound consumer takes
field 1 — one parser, one section-scoping rule, no second copy (affine-tpb).

An unrecognised category exits 2 in both directions. It is a broken manifest
rather than a policy violation, and defaulting it to ADDITIVE is exactly how a
fork-local patch would ship to upstream unnoticed."
```

---

### Task 3: Fail outbound when the change set touches a FORK-LOCAL file

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (checks + report)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Make `FORKLOCAL` a view of the dump, not a sibling of it**

Do this before anything else — it is the moment `FORKLOCAL` starts carrying weight.

Task 2 built `CLASSIFIED` (what `--dump-rows` prints) and `FORKLOCAL` (what this task consumes) side by side inside the same `case` dispatch. They agree today, but nothing makes them agree: moving only the `FORKLOCAL` append from one `case` arm to the other fully inverts the list this task acts on, and the whole suite still passes — the dump keeps printing the correct pairing while `FORKLOCAL` holds exactly the wrong files. The fixture that observes the dump cannot see it.

Delete the `FORKLOCAL="${FORKLOCAL}${p}"$'\n'` append from the `case` arm, and derive the list from the observed value after the loop instead:

```bash
# FORKLOCAL is DERIVED from CLASSIFIED — the same value --dump-rows prints — so
# the list this guard acts on is the list an operator can inspect. Building the
# two in parallel would let them drift, and a fixture over the dump could not
# see it. Exact field match, never a substring: a marker line must not be
# mistaken for a classification.
FORKLOCAL="$(printf '%s' "$CLASSIFIED" | awk -F'\t' '$2=="FORK-LOCAL CORE PATCH"{print $1}' | sort -u)"
```

Amend the comment above the classification block at the same time: it currently claims the dump can observe a bug in the dispatch itself, which was only true of the predicate, not of the assignment. After this change it is true of both.

Confirm the suite is unchanged, then verify the coupling is real: temporarily swap the two `case` arm bodies in a scratch copy and check the dump fixture goes red. Delete the scratch copy.

- [ ] **Step 2: Write the failing test**

Append to `scripts/woven-manifest-guard.test.sh`, before the summary block:

```bash
# --- 9. the leak: a branch off woven/main carries the core auth patch --------
# HEAD descends from woven/main, so oidc.ts diverges from the baseline. That is
# exactly the branch someone would cut to upstream a small additive fix.
echo "-- outbound: HEAD carries a FORK-LOCAL CORE PATCH"
run_guard --outbound --head HEAD
expect_rc 1 "policy violation"
expect_names "$OIDC_PATH"

# --- 10. ADDITIVE rows must NOT trip it --------------------------------------
# The fixture that catches a parser reading the wrong column: seed/index.ts and
# build-test.yml also diverge from the baseline, and both are ADDITIVE.
echo "-- outbound: ADDITIVE divergence is not a leak"
grep -qF -- "$SEED_PATH" "$OUT" && bad "outbound named an ADDITIVE file: $SEED_PATH" || ok "ADDITIVE $SEED_PATH not named"
grep -qF -- ".github/workflows/build-test.yml" "$OUT" && bad "outbound named an ADDITIVE file: build-test.yml" || ok "ADDITIVE build-test.yml not named"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh 2>&1 | tail -8`
Expected: FAIL — `exit 0; expected 1 (policy violation)`. The flag is parsed and the categories are classified, but nothing acts on them.

- [ ] **Step 4: Branch the two modes**

Placement matters and is a correctness requirement, not tidiness. Outbound must run **after** `UNMANIFESTED` is computed, and must fail on it before consulting `FORKLOCAL`.

The reason: the outbound answer is derived from the manifest, so a row the parser fails to read silently drops its file out of `FORKLOCAL` — and an empty `FORKLOCAL` is indistinguishable from "nothing to leak". Markdown has more legal ways to write a row than a parser can be trusted to cover. Requiring every upstream-owned change to be manifested first closes that whole class at once: a row that fails to parse makes its file unmanifested, which is already a failure. Any future parser gap then fails closed by construction rather than by having been anticipated.

In `scripts/woven-manifest-guard.sh`, find the `UNMANIFESTED=` assignment under `# ---- check 1:` and insert this block immediately **after** it (not before — `UNMANIFESTED` must already be set):

```bash
# ---- OUTBOUND mode: don't leak a fork patch to upstream --------------------
# Asks an ADDITIONAL question to the inbound one, over the same inputs: not just
# "is this divergence declared?" but "is this change set carrying something
# marked NEVER-upstream?".
#
# The unmanifested check runs FIRST and is fatal here too. FORKLOCAL is derived
# from the manifest, so a row the parser cannot read silently leaves the set, and
# an empty set looks exactly like "nothing to leak". An unreadable row makes its
# file unmanifested, so gating on that makes every parser gap fail closed —
# including shapes nobody anticipated. It also means the two checks can never
# disagree: a branch cannot be "safe to send upstream" while carrying a
# divergence the fork has not declared.
#
# LEAKED is compared against CHANGED rather than UPSTREAM_OWNED because that is
# the honest question — though a FORK-LOCAL row is upstream-owned by
# construction, so in practice the two agree.
if [ "$OUTBOUND" -eq 1 ]; then
  if [ -n "$UNMANIFESTED" ]; then
    err "cannot judge this change set: upstream-owned file(s) with no manifest row:"
    while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$UNMANIFESTED"
    err ""
    err "  An undeclared divergence has no category, so it cannot be cleared for"
    err "  upstream. Add a row to ${MANIFEST#"$REPO_ROOT/"} — or revert the change."
    exit 1
  fi
  LEAKED="$(comm -12 <(printf '%s\n' "$CHANGED"   | sed 's#^\./##' | sed '/^$/d' | sort -u) \
                     <(printf '%s\n' "$FORKLOCAL" | sed '/^$/d' | sort -u))"
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

```

Everything below stays as the inbound path. Outbound returns before reaching the STALE check and the report, so the two modes never interleave.

Add a fixture for the new ordering, since it is the thing that makes every parser gap safe:

```bash
# --- 9b. outbound refuses to judge an undeclared divergence ------------------
# Not a duplicate of the inbound unmanifested fixture: it pins the ORDERING.
# If outbound consulted FORKLOCAL first, a manifest row that failed to parse
# would drop its file out of the set and the leak check would pass vacuously.
echo "-- outbound: an unmanifested upstream-owned file is not judgeable"
grep -v -- "providers/oidc.ts" "$MANIFEST" >"$TMPDIR_T/m-nooidc.md"
run_guard --outbound --manifest "$TMPDIR_T/m-nooidc.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$OIDC_PATH"
```

- [ ] **Step 5: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: every prior assertion still green, plus 6 new ones (fixtures 9, 9b and 10). Record the new total — later tasks compare against it rather than a fixed number.

- [ ] **Step 6: Check it by hand against the real tree**

```bash
scripts/woven-manifest-guard.sh --outbound --head HEAD; echo "rc=$?"
```

Expected: `rc=1`, naming `packages/backend/server/src/plugins/oauth/providers/oidc.ts` and nothing else.

```bash
scripts/woven-manifest-guard.sh --head HEAD; echo "rc=$?"
```

Expected: `rc=0` — inbound still clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/woven-manifest-guard.sh scripts/woven-manifest-guard.test.sh
git commit -m "feat(woven): outbound guard fails on a FORK-LOCAL CORE PATCH (affine-hn1.4)

Delivers affine-cm9's unbuilt requirement and affine-hn1's third success
criterion.

Outbound is an ADDITIONAL question, not a separate one: it runs the unmanifested
check first and fails on it before consulting FORKLOCAL. That is what makes a
parser gap safe. FORKLOCAL is derived from the manifest, so a row the parser
cannot read silently leaves the set and an empty set looks exactly like nothing
to leak -- but an unreadable row also makes its file unmanifested, so gating on
that closes the whole class, including shapes nobody anticipated.

ADDITIVE divergence is explicitly asserted not to trip the check, which is the
fixture that catches a parser reading the wrong column."
```

---

### Task 4: Prove a correctly-based branch passes

**Files:**

- Test: `scripts/woven-manifest-guard.test.sh`

This is the counter-fixture to Task 3. Without it, a guard that failed unconditionally would pass every test so far.

- [ ] **Step 1: Write the test**

Append to `scripts/woven-manifest-guard.test.sh`, before the summary block:

```bash
# --- 11. known-good outbound: a branch built FROM the baseline ---------------
# The counter-fixture: a guard that simply always failed would satisfy #9. This
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
fi
```

`git ls-tree` supplies the real mode and blob so the fixture cannot drift from the file's actual permissions — `build-test.yml` is `100644`, but hardcoding that would silently break if it ever changed.

- [ ] **Step 2: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: the total from task 3, plus 1.

This should pass immediately — Task 3 already implemented the behaviour. If it fails, the outbound check is comparing against the wrong base.

- [ ] **Step 3: Commit**

```bash
git add scripts/woven-manifest-guard.test.sh
git commit -m "test(woven): known-good outbound fixture (affine-hn1.4)

The counter-fixture to the leak case: a guard that always failed would satisfy
every outbound assertion so far. Builds the branch woven-upstream-branch.sh will
build — baseline plus one ADDITIVE file — with plumbing, touching no branch,
index or working tree."
```

---

### Task 5: Record upstream's identity in the baseline file

**Files:**

- Modify: `scripts/woven-upstream-baseline`

The pre-push hook must match the destination **URL**, not the remote's name — a remote called `upstream` proves nothing, and a second remote pointing at the same place would bypass a name check. Nothing in the repo currently records which repository upstream is.

- [ ] **Step 1: Add the field**

Append to `scripts/woven-upstream-baseline`:

```
# The upstream repository, in owner/repo form. Read by .husky/pre-push to decide
# whether a push destination is upstream — matched against the remote URL, not
# the remote's NAME: a remote called "upstream" proves nothing, and a second
# remote pointing at the same place would slip past a name check.
UPSTREAM_REPO=toeverything/AFFiNE
```

- [ ] **Step 2: Verify both consumers still parse the file**

```bash
sed -n 's/^UPSTREAM_COMMIT=//p' scripts/woven-upstream-baseline | head -1
sed -n 's/^UPSTREAM_REPO=//p'   scripts/woven-upstream-baseline | head -1
```

Expected: `b4c8548c09da21b2898443559a5b846f0ccf5dd8` then `toeverything/AFFiNE`.

- [ ] **Step 3: Confirm the guard is unaffected**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: unchanged from task 4 — this task adds no fixtures, and a changed count here means the baseline file edit broke parsing.

- [ ] **Step 4: Commit**

```bash
git add scripts/woven-upstream-baseline
git commit -m "feat(woven): record UPSTREAM_REPO in the baseline (affine-hn1.4)

The pre-push hook matches the push destination URL rather than the remote's
name, so it needs upstream's identity stated somewhere. It belongs next to
UPSTREAM_COMMIT: the file already exists to give the upstream pin one home."
```

---

### Task 6: `woven-upstream-branch.sh` — a branch that cannot carry a leak

**Files:**

- Create: `scripts/woven-upstream-branch.sh`
- Test: `scripts/woven-upstream-branch.test.sh`

**Design note:** the spec says the script refuses "before creating anything". It achieves that by building the candidate commit with plumbing and asking the guard about it, then creating the branch only if the guard is clean — the same technique the fixtures use. This keeps a single implementation of "is this fork-local": the script contains no manifest parsing of its own.

- [ ] **Step 1: Write the failing test**

Create `scripts/woven-upstream-branch.test.sh`:

```bash
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
```

- [ ] **Step 2: Make it executable and run it to verify it fails**

```bash
chmod +x scripts/woven-upstream-branch.test.sh
scripts/woven-upstream-branch.test.sh
```

Expected: `FATAL: .../scripts/woven-upstream-branch.sh missing or not executable`, exit 2.

- [ ] **Step 3: Write the script**

Create `scripts/woven-upstream-branch.sh`:

```bash
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
git rev-parse --verify --quiet "$BRANCH" >/dev/null && die "branch $BRANCH already exists"

# Build the candidate commit with plumbing against a scratch index, so nothing
# exists to clean up if the guard refuses it.
TMP_INDEX="$(mktemp -u)"
trap 'rm -f "$TMP_INDEX"' EXIT
GIT_INDEX_FILE="$TMP_INDEX" git read-tree "$BASE_SHA" || die "could not seed a scratch index from the baseline"

for p in "$@"; do
  entry="$(git ls-tree "$FROM_SHA" -- "$p")"
  [ -n "$entry" ] || die "no such file at ${FROM}: $p"
  mode="$(printf '%s' "$entry" | awk '{print $1}')"
  blob="$(printf '%s' "$entry" | awk '{print $3}')"
  GIT_INDEX_FILE="$TMP_INDEX" git update-index --add --cacheinfo "${mode},${blob},${p}" \
    || die "could not stage $p"
  log "carrying $p"
done

TREE="$(GIT_INDEX_FILE="$TMP_INDEX" git write-tree)"
[ -n "$TREE" ] || die "could not write the candidate tree"
COMMIT="$(git commit-tree "$TREE" -p "$BASE_SHA" -m "${NAME}: prepared for upstream from ${BASE:0:9}")"
[ -n "$COMMIT" ] || die "could not build the candidate commit"

# One definition of "is this a leak", and it is not in this file.
if ! "$GUARD" --outbound --head "$COMMIT"; then
  err "refusing to create $BRANCH — see the guard output above."
  exit 1
fi

git branch "$BRANCH" "$COMMIT" || die "could not create $BRANCH"
ok "created $BRANCH from ${BASE:0:9} with $# file(s)"

if [ "$SWITCH" -eq 1 ]; then
  git switch "$BRANCH" || die "branch created but could not switch to it"
fi

log "This branch is a STARTING POINT — review, cherry-pick and squash as needed."
log "pre-push re-checks it against \$UPSTREAM_REPO before it leaves your machine."
exit 0
```

- [ ] **Step 4: Make both executable for git**

```bash
chmod +x scripts/woven-upstream-branch.sh scripts/woven-upstream-branch.test.sh
git update-index --chmod=+x scripts/woven-upstream-branch.sh 2>/dev/null || true
```

The `git update-index --chmod=+x` matters after `git add`: a file added without the executable bit cannot be run by CI. Step 6 verifies it.

- [ ] **Step 5: Run the tests**

Run: `scripts/woven-upstream-branch.test.sh`
Expected: `== 8 passed, 0 failed ==`

If test 2 reports "a branch was left behind", the guard call is happening after `git branch` rather than before it.

- [ ] **Step 6: Commit, and verify the mode landed**

```bash
git add scripts/woven-upstream-branch.sh scripts/woven-upstream-branch.test.sh
git update-index --chmod=+x scripts/woven-upstream-branch.sh scripts/woven-upstream-branch.test.sh
git commit -m "feat(woven): woven-upstream-branch.sh, a branch that cannot carry a leak (affine-hn1.4)

Branches from UPSTREAM_COMMIT rather than woven/main and carries over only the
named files, so a fork-local patch is absent by construction rather than caught
after the fact.

The candidate commit is built with plumbing and handed to the guard BEFORE any
branch exists, so a refusal leaves nothing to clean up — and the script contains
no manifest parsing of its own. One definition of 'is this a leak'."
git show --stat --format='' HEAD | head -5
```

Expected: both files listed as `create mode 100755`.

---

### Task 7: `.husky/pre-push` — refuse a push aimed at upstream

**Files:**

- Create: `.husky/pre-push`, `scripts/woven-pre-push.test.sh`

- [ ] **Step 1: Write the failing test**

Create `scripts/woven-pre-push.test.sh`:

```bash
#!/usr/bin/env bash
#
# woven-pre-push.test.sh — fixtures for the outbound pre-push hook.
#
# Invokes the hook directly with synthetic remote URLs, so both directions are
# asserted without performing a real push. git passes the remote NAME as $1 and
# the remote URL as $2; the hook must key on the URL, because a remote called
# "upstream" proves nothing.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HOOK="$REPO_ROOT/.husky/pre-push"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK missing" >&2; exit 2; }

PASS=0; FAIL=0
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
ok()  { printf '%s\n' "${c_grn}  ✔${c_rst} $*"; PASS=$((PASS+1)); }
bad() { printf '%s\n' "${c_red}  ✗${c_rst} $*" >&2; FAIL=$((FAIL+1)); }

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
OUT="$TMPDIR_T/out.txt"; RC=0
# </dev/null: the hook must not depend on the stdin ref list, which is empty for
# a branch the remote has not seen.
run_hook() { sh "$HOOK" "$1" "$2" >"$OUT" 2>&1 </dev/null; RC=$?; }
dump()     { sed 's/^/     | /' "$OUT" >&2; }

echo "== woven pre-push fixtures =="

# HEAD descends from woven/main and so carries oidc.ts.
echo "-- upstream destination: refused"
for url in "https://github.com/toeverything/AFFiNE.git" \
           "git@github.com:toeverything/AFFiNE.git" \
           "https://github.com/toeverything/AFFiNE"; do
  run_hook "some-remote-name" "$url"
  if [ "$RC" -ne 0 ]; then ok "refused $url"; else bad "ALLOWED $url — this is the leak"; dump; fi
done

echo "-- fork destination: allowed"
for url in "git@github.com:aRustyDev/AFFiNE.git" \
           "https://github.com/aRustyDev/AFFiNE.git" \
           "github-kapiraman:aRustyDev/AFFiNE.git"; do
  run_hook "origin" "$url"
  if [ "$RC" -eq 0 ]; then ok "allowed $url"; else bad "refused $url — false positive"; dump; fi
done

# The remote's NAME must carry no weight either way.
echo "-- the remote NAME is not the signal"
run_hook "upstream" "git@github.com:aRustyDev/AFFiNE.git"
if [ "$RC" -eq 0 ]; then ok "a remote NAMED upstream pointing at the fork is allowed"; else bad "keyed on the name, not the URL"; dump; fi

echo
printf '%s\n' "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x scripts/woven-pre-push.test.sh
scripts/woven-pre-push.test.sh
```

Expected: `FATAL: .../.husky/pre-push missing`, exit 2.

- [ ] **Step 3: Write the hook**

Create `.husky/pre-push`:

```sh
# woven pre-push — refuse to push a FORK-LOCAL CORE PATCH to upstream.
#
# git passes the remote NAME as $1 and the remote URL as $2. We key on the URL:
# a remote called "upstream" proves nothing, and a second remote pointing at the
# same place would slip past a name check. UPSTREAM_REPO lives in
# scripts/woven-upstream-baseline, next to the commit pin.
#
# Guards the branch TIP against the baseline rather than the pushed range: git
# supplies the range on stdin, and the remote sha is all-zeros for a branch the
# remote has not seen. The tip-vs-baseline comparison is the one the guard
# already makes, and has no such edge case.
#
# Pure sh, no node: this must work in a checkout where nothing is installed.
#
# This is a seatbelt, not a lock — `git push --no-verify` walks past it. The CI
# job on upstream/** is the backstop.

remote_url="${2:-}"
[ -n "$remote_url" ] || exit 0

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
baseline="$repo_root/scripts/woven-upstream-baseline"
guard="$repo_root/scripts/woven-manifest-guard.sh"
[ -f "$baseline" ] || exit 0
[ -x "$guard" ]    || exit 0

upstream_repo="$(sed -n 's/^UPSTREAM_REPO=//p' "$baseline" | head -1)"
[ -n "$upstream_repo" ] || exit 0

# Case-insensitively substring-match owner/repo against the URL, with and
# without a .git suffix. Covers https, ssh, and ssh-alias forms.
needle="$(printf '%s' "$upstream_repo" | tr '[:upper:]' '[:lower:]')"
haystack="$(printf '%s' "$remote_url" | tr '[:upper:]' '[:lower:]' | sed 's/\.git$//')"

case "$haystack" in
  *"$needle") ;;
  *"$needle"/*) ;;
  *) exit 0 ;;
esac

printf '%s\n' "[woven pre-push] destination is UPSTREAM ($upstream_repo) — running the outbound guard." >&2
if "$guard" --outbound --head HEAD; then
  exit 0
fi

printf '%s\n' "[woven pre-push] PUSH REFUSED. This branch carries a FORK-LOCAL CORE PATCH." >&2
printf '%s\n' "[woven pre-push] Prepare an upstream branch instead:" >&2
printf '%s\n' "[woven pre-push]   scripts/woven-upstream-branch.sh <name> <path>..." >&2
exit 1
```

- [ ] **Step 4: Run the tests**

```bash
chmod +x .husky/pre-push
scripts/woven-pre-push.test.sh
```

Expected: `== 7 passed, 0 failed ==`

If the fork URLs are refused, the `case` match is too loose — check that `aRustyDev/AFFiNE` does not contain `toeverything/AFFiNE` as a substring (it does not; a failure here means the needle lost its owner half).

- [ ] **Step 5: Commit**

```bash
git add .husky/pre-push scripts/woven-pre-push.test.sh
git update-index --chmod=+x .husky/pre-push scripts/woven-pre-push.test.sh
git commit -m "feat(woven): pre-push hook refuses an upstream-directed leak (affine-hn1.4)

Keys on the destination URL rather than the remote's NAME, and guards the branch
tip against the baseline rather than the pushed range — git reports an all-zeros
remote sha for a branch the remote has not seen, and the tip comparison is the
one the guard already makes.

Pure sh with no node dependency, so it works in a checkout where nothing is
installed. Fixtures invoke it directly with synthetic URLs, asserting both
directions without a real push, including that a remote NAMED upstream but
pointing at the fork is allowed."
```

---

### Task 8: Wire the CI backstop

**Files:**

- Modify: `.github/workflows/woven-manifest-guard.yml`

- [ ] **Step 1: Add the push trigger**

Replace the `on:` block with:

```yaml
on:
  pull_request:
    branches:
      - woven/main
  # The OUTBOUND backstop. A workflow in this fork CANNOT gate a PR into
  # toeverything/AFFiNE — pull_request runs workflows from the BASE repo, so
  # upstream runs upstream's and ours never execute. The branch prefix is the
  # only signal available here, which is why woven-upstream-branch.sh applies it
  # for you rather than leaving it to memory.
  push:
    branches:
      - 'upstream/**'
  workflow_dispatch:
```

- [ ] **Step 2: Move every fixture suite into a job that runs on BOTH triggers**

The four fixture suites are hermetic and fast, and they are what keeps the guard honest. If they only ran on push to `upstream/**` — a rare event — layers 1 and 2 would go untested on ordinary development. Equally, leaving them only on the PR trigger means a push to an `upstream/**` branch never re-checks them.

So: fixtures run always; the two *verdicts* are gated by event.

Restructure `jobs:` into three. First, the always-on fixtures:

```yaml
  fixtures:
    name: Guard fixtures
    runs-on: ubuntu-latest
    steps:
      # fetch-depth: 0 is REQUIRED. Several fixtures build throwaway commits
      # parented on the upstream baseline, which is reachable only as a merge
      # parent — a shallow checkout cannot resolve it and they fail as exit 2.
      - name: Checkout (full history — baseline is a merge parent)
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Manifest guard fixtures
        run: scripts/woven-manifest-guard.test.sh

      - name: Branch-preparer fixtures
        run: scripts/woven-upstream-branch.test.sh

      - name: Pre-push hook fixtures
        run: scripts/woven-pre-push.test.sh

      # The sweep itself is NOT run in CI — bd needs a shared Dolt server that
      # runners cannot reach — but its fixtures use a frozen bead corpus, so the
      # affine-hn1.3 v0.27.4 dry-run stays permanently verified.
      - name: Drift-sweep fixtures (frozen v0.27.4 dry-run)
        run: scripts/woven-drift-sweep.test.sh
```

- [ ] **Step 3: Reduce the existing job to the inbound verdict, gated to PRs**

Strip the fixture steps out of `manifest-guard` — they moved to `fixtures` — leaving the checkout and the guard run, and gate it:

```yaml
  manifest-guard:
    name: Upstream divergence is manifested
    if: github.event_name != 'push'
    runs-on: ubuntu-latest
```

A push to `upstream/**` has no unmanifested divergence to find, so the inbound verdict is meaningless there.

- [ ] **Step 3b: Add the outbound verdict, gated to pushes**

```yaml
  upstream-leak-guard:
    name: No fork-local patch on an upstream branch
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Checkout (full history — baseline is a merge parent)
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Outbound leak guard
        run: scripts/woven-manifest-guard.sh --outbound
```

Note what this job does **not** do: it does not run on `workflow_dispatch`. A manual dispatch has no branch guarantee, and `--outbound` on `woven/main` correctly exits 1 — a red run that means nothing would train people to ignore it.

- [ ] **Step 4: Check the YAML parses**

```bash
npx js-yaml .github/workflows/woven-manifest-guard.yml > /dev/null && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 5: Confirm both jobs are declared**

```bash
grep -n 'manifest-guard:\|upstream-leak-guard:\|if:' .github/workflows/woven-manifest-guard.yml
```

Expected: both job keys present, each with its own `if:`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/woven-manifest-guard.yml
git commit -m "ci(woven): run the outbound guard on push to upstream/** (affine-hn1.4)

Extends the existing workflow rather than adding a second one — it already runs
the fixture suites, and two workflows over overlapping fixtures would drift.

CI keys on the branch prefix because it has no other signal: a PR into upstream
runs upstream's workflows, never ours. The prefix is weak on its own, which is
why woven-upstream-branch.sh applies it and pre-push covers the branches that
never got it. Each job is gated by event so neither runs where it is meaningless."
```

---

### Task 9: Document the rule where people will meet it

**Files:**

- Modify: `scripts/woven-patch-manifest.md` (merge-time checklist), `scripts/woven-agent-bootstrap.md` (§7)

- [ ] **Step 1: Add the outbound rule to the manifest**

In `scripts/woven-patch-manifest.md`, directly below the paragraph beginning "That guard is **`scripts/woven-manifest-guard.sh`**", insert:

````markdown
The same script enforces the **outbound** direction with `--outbound` (bead
`affine-hn1.4`): it fails when a change set touches a file whose row says
**FORK-LOCAL CORE PATCH**, which `affine-cm9` requires never reach upstream. That
makes column 2 load-bearing — a row's category is now enforced, not documentation.
An unrecognised category exits 2 rather than being assumed ADDITIVE.

To prepare a contribution for upstream, do not branch from `woven/main` — it
carries every fork-local patch the fork has ever made. Use:

```bash
scripts/woven-upstream-branch.sh <name> <path>...
```
````

It branches from `UPSTREAM_COMMIT`, carries over only the files you name, and
names the branch `upstream/<name>` — the prefix the CI backstop keys on.

````

- [ ] **Step 2: Add the upstream-contribution path to the bootstrap**

In `scripts/woven-agent-bootstrap.md`, append to the end of `## 7. Deployment / CD`:

```markdown
### Contributing back to upstream

`affine-cm9` allows ADDITIVE changes to be upstreamed and forbids FORK-LOCAL CORE
PATCHes from ever reaching `toeverything/AFFiNE`. Three things enforce that, all
calling `scripts/woven-manifest-guard.sh --outbound`:

1. `scripts/woven-upstream-branch.sh <name> <path>...` — branches from the
   upstream baseline rather than `woven/main`, so the branch cannot carry a
   fork-local patch. Start here.
2. `.husky/pre-push` — refuses a push whose destination URL is `UPSTREAM_REPO`.
   Bypassable with `git push --no-verify`.
3. CI on push to `upstream/**` — the backstop for a push the hook did not see.

The prepared branch is a starting point: review, cherry-pick and squash it as
needed. The clean result the preparer reports describes the branch at creation,
not the branch you eventually push — which is why the last two exist.
````

- [ ] **Step 3: Confirm the manifest still parses after editing**

The guard reads this file. An edit that broke the table heading or a row would be caught here.

Run: `scripts/woven-manifest-guard.test.sh`
Expected: unchanged from task 4. A changed count here means the manifest edit broke the guard's parsing of its own table.

- [ ] **Step 4: Commit**

```bash
git add scripts/woven-patch-manifest.md scripts/woven-agent-bootstrap.md
git commit -m "docs(woven): document the outbound rule and how to upstream a change (affine-hn1.4)

The manifest gains the outbound half next to the inbound one, and says plainly
that column 2 is now enforced rather than documentation. The bootstrap gains the
path a contributor actually follows, including that the prepared branch is a
starting point and the last two layers are what check its final content."
```

---

### Task 10: Full verification and bead closure

**Files:** none modified

- [ ] **Step 1: Run every suite**

```bash
scripts/woven-manifest-guard.test.sh
scripts/woven-upstream-branch.test.sh
scripts/woven-pre-push.test.sh
scripts/woven-drift-sweep.test.sh
```

Expected: the task 4 total, then `8 passed`, `7 passed`, `11 passed` — all with `0 failed`.

- [ ] **Step 2: Run both guard directions against the real tree**

```bash
scripts/woven-manifest-guard.sh; echo "inbound  rc=$?"
scripts/woven-manifest-guard.sh --outbound; echo "outbound rc=$?"
```

Expected: `inbound rc=0` and `outbound rc=1`. **Outbound failing on `woven/main` is correct** — this branch carries `oidc.ts`. It is the whole point. Outbound is only expected to pass on a branch built from the baseline.

- [ ] **Step 3: Confirm every new file is executable**

```bash
git ls-files -s scripts/woven-upstream-branch.sh scripts/woven-upstream-branch.test.sh scripts/woven-pre-push.test.sh .husky/pre-push
```

Expected: every line begins `100755`. A `100644` here means CI cannot run that file.

- [ ] **Step 4: Run the drift sweep**

```bash
scripts/woven-drift-sweep.sh
```

Read the candidates against this change. `affine-vap` is expected to surface — it must land its row marked FORK-LOCAL CORE PATCH, which is now enforced rather than advisory.

- [ ] **Step 5: Note the dependency on `affine-vap`**

```bash
bd note affine-vap "affine-hn1.4 landed the outbound leak guard: scripts/woven-manifest-guard.sh --outbound now reads column 2 of the patch manifest and FAILS when a change set touches a row marked FORK-LOCAL CORE PATCH. When this bead adds the seat-limit patch, its manifest row's category is load-bearing, not documentation — an unrecognised category exits 2, and a row marked ADDITIVE would silently permit the patch onto an upstream-directed branch. Mark it FORK-LOCAL CORE PATCH."
```

- [ ] **Step 6: Open the PR**

```bash
git push -u origin claude/affine-hn1.4-leak-guard
```

Target the **fork**, explicitly. `gh` resolves to the parent repo by default when an `upstream` remote is present — the very near-miss this bead exists to prevent:

```bash
gh pr create --repo aRustyDev/AFFiNE --base woven/main --title "feat(woven): outbound upstream-leak guard (affine-hn1.4)" --body-file .claude/plans/upstream-leak-guard/DESIGN.md
```

- [ ] **Step 7: Close the bead once CI is green**

Do not close before the checks pass. The close reason must name the evidence: the three fixture counts, the two guard exit codes, and the PR number.

---

## Notes for the implementer

**Do not add an override flag.** Every layer will at some point be inconvenient. "Never upstream" is the entire rule; the escape hatch is editing the manifest row in a reviewed commit, where someone can see it.

**`--outbound` failing on `woven/main` is correct, not a bug.** Do not "fix" it. The only branch outbound should pass on is one based on the upstream baseline. Task 4's fixture is what proves the guard can say yes at all.

**Do not duplicate the manifest parser.** `woven-upstream-branch.sh` and `.husky/pre-push` both call the guard and read its exit code. If you find yourself parsing the manifest anywhere else, the design has drifted.

**Keep the hook free of dependencies.** `.husky/pre-push` is plain `sh` calling a bash script, and must stay that way: it has to work in a checkout where nothing is installed. `scripts/woven-pre-push.test.sh` invokes it directly rather than through git, so its coverage never depends on the hook being wired up.
