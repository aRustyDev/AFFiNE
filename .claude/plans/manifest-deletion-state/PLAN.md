# Declarable Removal in the Patch Manifest — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a fork-deleted or fork-renamed upstream-owned file a reachable green state in both guard directions, by letting the manifest declare removal instead of inferring it from an absent path.

**Architecture:** The `## Diverged upstream-owned files` table gains a fifth column, `State`. `manifest_rows()` emits it as a third and fourth field (`state`, and a `MOVED` destination). The single `path_present()` test becomes a small state machine producing four distinct verdicts — `STALE`, `RESURRECTED`, `OBSOLETE`, `MOVED`-destination-missing — each with an achievable fix. `Category` is untouched, so the outbound gate needs no change except clause 3: a `MOVED` destination joins `FORKLOCAL` when the row is FORK-LOCAL CORE PATCH.

**Tech Stack:** POSIX `sh` / `bash`, `awk`, git plumbing, no toolchain.

**Design:** `.claude/plans/manifest-deletion-state/DESIGN.md`

**Bead:** `affine-83p`

---

## Before you start

Run every command from the repository root.

This box has **no system-wide node or yarn**. Every `git commit` must run through the repo env, or the husky pre-commit hook dies with `yarn: command not found`:

```bash
micromamba run -n affine git commit -m "..."
```

The guard and its suite are pure `bash`/`awk` and need no toolchain, so they run directly:

```bash
scripts/woven-manifest-guard.test.sh
```

Markdown formatting is handled by the pre-commit hook (`lint-staged` runs `oxfmt` over staged files), so the manifest table's alignment needs no step of its own — **but be aware oxfmt reformats markdown tables**, so a table you hand-align will come back re-aligned. That is expected, not a conflict.

**Baseline before you touch anything.** The suite must be green at the start, or you cannot tell your own breakage from inherited breakage:

```bash
scripts/woven-manifest-guard.test.sh; echo "rc=$?"
```

Expected: every fixture `✔`, `rc=0`.

## File Structure

**Modified:**

- `scripts/woven-manifest-guard.sh` — `manifest_rows()` emits state + destination; the classifier gains `BADSTATE`; the row-resolution loop becomes state-aware and grows three new verdicts; `FORKLOCAL` gains clause 3. **All policy lives here.**
- `scripts/woven-manifest-guard.test.sh` — eleven new fixtures (18–28) alongside the existing seventeen.
- `scripts/woven-patch-manifest.md` — the table gains the `State` column and the legend documents its vocabulary.

**Created:** nothing. This is a change to one engine and its manifest.

**Boundary:** the guard is the only file that decides what a State value means. The manifest is data; the test file asserts behaviour. No second parser anywhere.

**A note on fixture numbers:** the task bodies below still cite the original plan's numbering (14–24), which — worked out before the suite's real shape was checked — collided with the pre-existing outbound fixtures 14–17. That numbering is left as-is in the steps below, as a historical record of what each task was actually told to do. The numbering that landed for Task 6 is 18–26 (see File Structure above and "Done when" below for the true mapping); fixtures 27 and 28 were added in review, on top of Task 6 rather than as part of its originally-planned set — 27 for the realistic add-only exploit shape clause 3 must also catch, 28 for a code-review finding that the outbound pre-gate itself needed extending to RESURRECTED, OBSOLETE and MOVED_GONE (see "Post-review correction" in DESIGN.md).

---

### Task 1: Parse the `State` column, fail closed on anything unrecognised

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (`manifest_rows()`, the classifier, `--dump-rows`)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the failing test**

Append to `scripts/woven-manifest-guard.test.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: the new fixture reports `✗ exit 1; expected 2` — the guard currently ignores the extra column entirely, so the row parses as PRESENT and the manifest looks unchanged.

- [ ] **Step 3: Emit state and destination from the parser**

In `scripts/woven-manifest-guard.sh`, replace the body of the `if (n >= 3 && match(f[2], ...))` block inside `manifest_rows()` with:

```awk
      if (n >= 3 && match(f[2], /`[^`]+`/)) {
        path = substr(f[2], RSTART + 1, RLENGTH - 2)
        cat = f[3]
        gsub(/[*_`]/, "", cat)
        sub(/^[[:space:]]+/, "", cat)
        sub(/[[:space:]]+$/, "", cat)
        # Column 5 (field 6) is State; absent or empty means PRESENT, which is
        # the STRICTER reading and so the fail-closed default. A MOVED row
        # carries its destination as a backticked path in the same cell: pull it
        # out and REMOVE it from the cell BEFORE normalisation, because
        # normalisation strips backticks and would otherwise leave the path
        # glued to the keyword, defeating the exact-match compare below.
        state = (n >= 6 ? f[6] : "")
        dest = ""
        if (match(state, /`[^`]+`/)) {
          dest = substr(state, RSTART + 1, RLENGTH - 2)
          state = substr(state, 1, RSTART - 1) substr(state, RSTART + RLENGTH)
        }
        gsub(/[*_`]/, "", state)
        sub(/^[[:space:]]+/, "", state)
        sub(/[[:space:]]+$/, "", state)
        if (state == "") state = "PRESENT"
        print path "\t" cat "\t" state "\t" dest
        next
      }
```

- [ ] **Step 4: Keep the existing consumers reading the right field**

`MANIFESTED` already takes field 1 and needs no change. The classifier loop must read four fields. Change its `read` and its `case` to:

```bash
BADCAT=""
BADSTATE=""
CLASSIFIED=""
while IFS=$'\t' read -r p c s d; do
  [ -n "$p" ] || continue
  case "$c" in
    "FORK-LOCAL CORE PATCH") cc="FORK-LOCAL CORE PATCH" ;;
    "ADDITIVE")              cc="ADDITIVE" ;;
    *)
      BADCAT="${BADCAT}${p}  [category: ${c:-<empty>}]"$'\n'
      cc="!BADCAT(${c:-<empty>})"
      ;;
  esac
  # State is validated independently of Category: the two columns answer
  # different questions and a bad value in either is a broken manifest.
  case "$s" in
    PRESENT|REMOVED)
      # A destination with no MOVED keyword means a half-edited cell. Ignoring
      # the path silently is how clause 3 stops applying without anyone noticing.
      [ -z "$d" ] || BADSTATE="${BADSTATE}${p}  [state: ${s} but carries destination '${d}']"$'\n'
      ;;
    MOVED)
      [ -n "$d" ] || BADSTATE="${BADSTATE}${p}  [state: MOVED with no destination path]"$'\n'
      ;;
    *)
      BADSTATE="${BADSTATE}${p}  [state: ${s:-<empty>}]"$'\n'
      ;;
  esac
  CLASSIFIED="${CLASSIFIED}${p}"$'\t'"${cc}"$'\t'"${s}"$'\t'"${d}"$'\n'
done <<< "$(printf '%s\n' "$ROWS" | grep -v '^!UNPARSED')"
```

- [ ] **Step 5: Reject a bad State with exit 2**

Directly after the existing `if [ -n "$BADCAT" ]; then ... exit 2; fi` block, add:

```bash
if [ -n "$BADSTATE" ]; then
  err "manifest row(s) in $MANIFEST with an unrecognised State — refusing to guess:"
  while IFS= read -r l; do [ -n "$l" ] && err "    $l"; done <<< "$BADSTATE"
  err ""
  err "  Column 5 must be empty (the file is present), REMOVED (this fork deletes it),"
  err "  or MOVED followed by the destination as a backticked path, e.g."
  err "    | \`old/path.ts\` | **ADDITIVE** | why | delete when | MOVED \`new/path.ts\` |"
  exit 2
fi
```

- [ ] **Step 6: Widen `--dump-rows` to show what the classifier saw**

The dump must keep printing exactly what the guard acts on. Change its printer to emit all four fields and update the usage comment above it:

```bash
# Prints what the parser AND the classifier saw — `path<TAB>category<TAB>state<TAB>destination`
# per row (destination empty unless MOVED), `!UNPARSED<TAB><raw line>` for one
# that didn't parse — then exits before any of the checks below can fail.
```

- [ ] **Step 7: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: fixture 14 now `✔ exit 2`, every pre-existing fixture still `✔`, `rc=0`. The live manifest has no State column, so every existing row defaults to PRESENT and behaves exactly as before.

- [ ] **Step 8: Commit**

```bash
micromamba run -n affine git commit -m "feat(woven): parse a State column in the patch manifest, fail closed on unknown values (affine-83p)"
```

---

### Task 2: A `REMOVED` row is satisfied by an absent path — the deadlock breaks

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (the row-resolution loop)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Add the shared fixture helpers**

Define these at **top level**, immediately after the existing `expect_names()` helper — not inside any fixture's `if`/`else`. Tasks 3–7 all reference them, and a helper defined inside a conditional branch is undefined in later fixtures whenever that branch is skipped.

```bash
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
```

- [ ] **Step 2: Write the failing test**

```bash
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
```

- [ ] **Step 3: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `✗ exit 1; expected 0`, with the dump showing `STALE manifest row(s)` naming `oidc.ts` — the loop still tests presence without consulting State.

- [ ] **Step 4: Make the row-resolution loop state-aware**

Replace the whole `# ---- check 2: rows whose path is gone from the tree` block with:

```bash
# ---- check 2: resolve each row against the tree, per its State --------------
# One predicate used to carry four meanings — upstream deleted it, THIS BRANCH
# deleted it, a rename moved it, or the row is a typo — and collapsed all four
# into "drop or repoint the row". A fork deletion is a diff against the baseline,
# so dropping the row just moved the failure to UNMANIFESTED. State separates
# them: a declared deletion is satisfied by absence, and STALE now fires only
# where absence really does implicate upstream. (affine-83p)
STALE=""
UNDIVERGED=""
RESURRECTED=""
OBSOLETE=""
MOVED_GONE=""

# Hoisted out of the loop: these were redefined on every iteration.
if [ "$WORKTREE" -eq 1 ]; then
  path_present() { [ -e "$REPO_ROOT/$1" ]; }
else
  path_present() { git cat-file -e "${HEAD_SHA}:${1}" 2>/dev/null; }
fi
base_present() { git cat-file -e "${BASE_SHA}:${1}" 2>/dev/null; }

while IFS=$'\t' read -r p c s d; do
  [ -n "$p" ] || continue
  case "$s" in
    PRESENT)
      if ! path_present "$p"; then
        STALE="${STALE}${p}"$'\n'
      elif ! printf '%s\n' "$UPSTREAM_OWNED" | grep -qxF -- "$p"; then
        UNDIVERGED="${UNDIVERGED}${p}"$'\n'
      fi
      ;;
    REMOVED|MOVED)
      # MOVED shares every source-side verdict with REMOVED; it only adds the
      # destination assertion below.
      if path_present "$p"; then
        RESURRECTED="${RESURRECTED}${p}"$'\n'
      elif ! base_present "$p"; then
        OBSOLETE="${OBSOLETE}${p}"$'\n'
      fi
      if [ "$s" = "MOVED" ] && ! path_present "$d"; then
        MOVED_GONE="${MOVED_GONE}${p} -> ${d}"$'\n'
      fi
      ;;
  esac
done <<< "$CLASSIFIED"
```

- [ ] **Step 5: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: fixture 15 `✔ exit 0`. Every existing fixture still `✔` — including fixture 4 (`stale row`), whose ghost path has no State cell and so stays PRESENT.

- [ ] **Step 6: Commit**

```bash
micromamba run -n affine git commit -m "fix(woven): a REMOVED manifest row is satisfied by an absent path (affine-83p)"
```

---

### Task 3: `RESURRECTED` and `OBSOLETE` verdicts

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (reporting block)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# --- 16. RESURRECTED: the row says the fork removes it, but it is back -------
# A safety property the guard did not previously have. An upstream merge that
# restores a file the fork deleted is otherwise completely silent.
echo "-- resurrected: State=REMOVED but the file is present"
mark_removed "$SEED_PATH" "$TMPDIR_T/m-resurrect.md"
run_guard --manifest "$TMPDIR_T/m-resurrect.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$SEED_PATH"

# --- 17. OBSOLETE: upstream deleted it too, so the row describes nothing -----
echo "-- obsolete: State=REMOVED on a path absent from the baseline"
GHOST_REMOVED="packages/backend/server/src/gone-from-both.ts"
sed "s|\`$OIDC_PATH\`|\`$GHOST_REMOVED\`|" "$MANIFEST" >"$TMPDIR_T/m-obs-1.md"
awk -v p="$GHOST_REMOVED" '
  $0 ~ p && /^\|/ { sub(/[[:space:]]*\|[[:space:]]*$/, " | **REMOVED** |"); }
  { print }
' "$TMPDIR_T/m-obs-1.md" >"$TMPDIR_T/m-obsolete.md"
run_guard --manifest "$TMPDIR_T/m-obsolete.md" --head HEAD
expect_rc 1 "policy violation"
expect_names "$GHOST_REMOVED"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: both report `✗ exit 0; expected 1`. Task 2 computes `RESURRECTED` and `OBSOLETE` but nothing reports them, so the guard exits clean.

- [ ] **Step 3: Report both**

In the reporting section, immediately after the existing `if [ -n "$STALE" ]; then ... fi` block, add:

```bash
if [ -n "$RESURRECTED" ]; then
  rc=1
  err "RESURRECTED — ${MANIFEST#"$REPO_ROOT/"} says this fork removes these files, but they are present:"
  while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$RESURRECTED"
  err "  An upstream merge probably restored them. Either delete them again, or —"
  err "  if the fork now keeps upstream's version — clear the State cell back to empty."
fi

if [ -n "$OBSOLETE" ]; then
  rc=1
  err "OBSOLETE row(s) in ${MANIFEST#"$REPO_ROOT/"} — marked REMOVED, but absent from the baseline too:"
  while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$OBSOLETE"
  err "  Upstream deleted the file as well, so the row no longer describes a divergence."
  err "  Drop the row."
fi
```

- [ ] **Step 4: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: fixtures 16 and 17 `✔ exit 1` and both name their path. All earlier fixtures still `✔`.

- [ ] **Step 5: Commit**

```bash
micromamba run -n affine git commit -m "feat(woven): RESURRECTED and OBSOLETE verdicts for REMOVED rows (affine-83p)"
```

---

### Task 4: `STALE` stops prescribing the opposite failure

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (STALE message, both inbound and outbound copies)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the failing test**

```bash
# --- 18. STALE names BOTH causes and both achievable fixes -------------------
# The acceptance criterion of affine-83p: the message must distinguish "absent
# because upstream deleted it" from "absent because this branch deleted it", and
# must not prescribe an action that produces the opposite failure.
echo "-- stale message: offers REMOVED as well as drop/repoint"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null; then
  bad "$OIDC_PATH already has uncommitted changes; skipping"
else
  restore_oidc() { git checkout -- "$OIDC_PATH" 2>/dev/null || true; }
  trap 'restore_oidc; rm -rf "$TMPDIR_T"' EXIT
  rm -f "$OIDC_PATH"
  run_guard   # live manifest: the row is PRESENT and undeclared
  expect_rc 1 "policy violation"
  expect_names "$OIDC_PATH" "REMOVED"
  restore_oidc
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `✔ exit 1` but `✗ output does not name REMOVED` — the message still offers only "drop the row, or repoint it".

- [ ] **Step 3: Rewrite the inbound STALE message**

Replace the existing inbound STALE `err` lines with:

```bash
if [ -n "$STALE" ]; then
  rc=1
  err "STALE manifest row(s) in ${MANIFEST#"$REPO_ROOT/"} — the path is not in the tree:"
  while IFS= read -r p; do [ -n "$p" ] && err "    $p"; done <<< "$STALE"
  err "  Two causes, two different fixes:"
  err "    * upstream deleted or renamed it  -> drop the row, or repoint it at the new path"
  err "    * THIS BRANCH deleted it          -> keep the row and set State to REMOVED"
  err "      (a rename: State = MOVED \`new/path\`)"
fi
```

- [ ] **Step 4: Rewrite the outbound STALE message the same way**

The outbound block carries its own copy of the advice ("Update or drop the row..."). Replace its stale-specific lines with the same two-cause form so the two directions cannot disagree:

```bash
      err "  A stale row's category no longer describes this tree. If upstream deleted or"
      err "  renamed the file, drop or repoint the row; if THIS BRANCH deleted it, set the"
      err "  row's State to REMOVED (or MOVED \`new/path\`) and run again."
```

- [ ] **Step 5: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: fixture 18 fully `✔`. All earlier fixtures still `✔`.

- [ ] **Step 6: Commit**

```bash
micromamba run -n affine git commit -m "fix(woven): STALE names both causes instead of prescribing the opposite failure (affine-83p)"
```

---

### Task 5: `MOVED` — the source is gone and the destination exists

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (reporting block)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the failing tests**

`git mv` is used rather than a hand-built file because it produces a _real_ rename: the destination becomes tracked and therefore appears in `git diff BASE`, exactly as it would in the change under test. An untracked destination would be skipped by the guard by design.

```bash
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
```

- [ ] **Step 2: Run them and check which one actually fails**

Run: `scripts/woven-manifest-guard.test.sh`

Expected: **fixture 19 already passes** (`✔ exit 0`) and **fixture 20 fails** (`✗ exit 0; expected 1`).

Only fixture 20 drives new code. Fixture 19 passes because Task 2's Step 4 already handles the source side — `path_present("$OIDC_PATH")` is false so it is not RESURRECTED, `base_present` is true so it is not OBSOLETE, the row keeps the source out of `UNMANIFESTED`, and the destination is fork-owned so it never enters `UPSTREAM_OWNED`. That makes fixture 19 a **characterization test**: it pins behaviour Task 2 produced as a side effect, so a later refactor cannot silently un-green a declared rename.

If fixture 19 fails here, do not proceed — something in Task 2's loop is wrong, and Step 3 will paper over it.

- [ ] **Step 3: Report a missing destination**

After the `OBSOLETE` block added in Task 3:

```bash
if [ -n "$MOVED_GONE" ]; then
  rc=1
  err "MOVED row(s) in ${MANIFEST#"$REPO_ROOT/"} whose destination is not in the tree:"
  while IFS= read -r l; do [ -n "$l" ] && err "    $l"; done <<< "$MOVED_GONE"
  err "  Point State at the path the file actually has now, or use REMOVED if the"
  err "  fork dropped it rather than relocating it."
fi
```

- [ ] **Step 4: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: fixtures 19 and 20 both `✔`. All earlier fixtures still `✔`.

- [ ] **Step 5: Commit**

```bash
micromamba run -n affine git commit -m "feat(woven): MOVED rows assert the destination exists (affine-83p)"
```

---

### Task 6: Clause 3 — a `MOVED` destination joins `FORKLOCAL`

This is the task that keeps the rename hole shut. Do not skip or reorder it.

**Corrected after Task 7 landed:** it no longer is. A later review proved, by
exhaustive case split, that once the outbound pre-gate consults every inbound
verdict via `INBOUND_UNCLEAN` (Task 7), clause 3's `print $4` stops changing
any exit code — RESURRECTED, LEAKED (via the source path) and OBSOLETE already
cover every case it used to. Clause 3 is now diagnostic (it names the
destination in a leak report); `INBOUND_UNCLEAN` is what actually keeps the
hole shut. See DESIGN.md's "Post-review correction" section for the full case
split. Still worth doing in its own step below, and still worth the fixture —
just not for the reason this line originally gave.

_(The fixture numbers below are the original plan's, since collided with the
pre-existing suite — see the numbering note under File Structure for what
actually landed: 18–26, plus fixture 27 and 28 added in review.)_

**Files:**

- Modify: `scripts/woven-manifest-guard.sh` (`FORKLOCAL` derivation)
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the failing test**

```bash
# --- 21. clause 3: outbound sees a FORK-LOCAL patch at its NEW address -------
# Without this, fixing the deadlock reintroduces the very leak --no-renames
# exists to prevent: the rename reaches green, the destination is fork-owned
# (absent at the baseline) and so falls outside UPSTREAM_OWNED, and outbound
# goes blind to a fully-present relocated core patch. This fixture is the only
# thing standing between the affine-83p fix and that regression.
echo "-- outbound: a MOVED FORK-LOCAL patch is caught at its destination"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null; then
  bad "$OIDC_PATH already has uncommitted changes; skipping"
else
  trap 'restore_move; rm -rf "$TMPDIR_T"' EXIT
  git mv "$OIDC_PATH" "$MOVED_DEST"
  run_guard --outbound --manifest "$TMPDIR_T/m-moved.md"
  expect_rc 1 "policy violation"
  expect_names "$MOVED_DEST"
  restore_move
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `✗ output does not name .../woven-oidc.ts`. Outbound may still exit 1 on the _source_ path, which is why `expect_names` on the destination — not the exit code alone — is the assertion that matters here.

- [ ] **Step 3: Add the destination to `FORKLOCAL`**

Replace the `FORKLOCAL` derivation with:

```bash
# FORKLOCAL is DERIVED from CLASSIFIED — the same value --dump-rows prints — so
# the list this guard acts on is the list an operator can inspect. Exact field
# match, never a substring: a marker line must not be mistaken for a
# classification.
#
# Clause 3 (affine-83p): a MOVED row's DESTINATION joins the set. The
# destination did not exist at the baseline, so it is fork-owned and falls
# outside UPSTREAM_OWNED entirely — without this line a renamed core patch is
# fully present in the tree and invisible to the outbound check.
FORKLOCAL="$(printf '%s' "$CLASSIFIED" | awk -F'\t' '
  $2=="FORK-LOCAL CORE PATCH" {
    print $1
    if ($3=="MOVED" && $4!="") print $4
  }' | sort -u)"
```

No new byte-literal handling is needed here, and that is worth understanding rather than assuming. The destination is intersected against `CHANGED`, which is already computed with `--no-renames` and `-c core.quotePath=false` under `LC_ALL=C`. A destination that C-quoted or collated away would drop out of the intersection, and clause 3 would fail open — so if you ever change how `CHANGED` is built, this line is downstream of that decision.

- [ ] **Step 4: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: fixture 21 `✔ exit 1` and `✔ output names .../woven-oidc.ts`. All earlier fixtures still `✔`.

- [ ] **Step 5: Commit**

```bash
micromamba run -n affine git commit -m "feat(woven): a MOVED destination joins the outbound FORK-LOCAL set (affine-83p)"
```

---

### Task 7: Prove the outbound policy for deletions needs no special case

No production code changes in this task. These fixtures assert the design's central claim — that deletion inherits the category's upstreamability — so that a later refactor cannot quietly break it.

**Files:**

- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the tests**

```bash
# --- 22. a REMOVED FORK-LOCAL file still cannot go upstream ------------------
# The branch would DELETE a file from upstream. Deletion inherits the row's
# category rather than needing a deletion policy of its own — this fixture is
# the evidence for that claim (affine-83p design, "Decision").
echo "-- outbound: deleting a FORK-LOCAL file is still a leak"
if ! git diff --quiet -- "$OIDC_PATH" 2>/dev/null; then
  bad "$OIDC_PATH already has uncommitted changes; skipping"
else
  trap 'restore_oidc; rm -rf "$TMPDIR_T"' EXIT
  rm -f "$OIDC_PATH"
  run_guard --outbound --manifest "$TMPDIR_T/m-removed.md"
  expect_rc 1 "policy violation"
  expect_names "$OIDC_PATH"
  restore_oidc
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi

# --- 23. a REMOVED ADDITIVE file IS sendable upstream ------------------------
# "The fork drops its own additive change" is a coherent diff to send.
echo "-- outbound: deleting an ADDITIVE file is clean"
if ! git diff --quiet -- "$SEED_PATH" 2>/dev/null; then
  bad "$SEED_PATH already has uncommitted changes; skipping"
else
  restore_seed() { git checkout -- "$SEED_PATH" 2>/dev/null || true; }
  trap 'restore_seed; rm -rf "$TMPDIR_T"' EXIT
  mark_removed "$SEED_PATH" "$TMPDIR_T/m-seed-removed.md"
  rm -f "$SEED_PATH"
  run_guard --outbound --manifest "$TMPDIR_T/m-seed-removed.md"
  expect_rc 0 "additive deletion is sendable"
  restore_seed
  trap 'rm -rf "$TMPDIR_T"' EXIT
fi
```

- [ ] **Step 2: Run the suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: both `✔` with **no production change**. If either fails, the design's claim is wrong and the outbound gate does need a deletion policy — stop and re-read the design's "Decision" section before writing any code.

- [ ] **Step 3: Commit**

```bash
micromamba run -n affine git commit -m "test(woven): deletion inherits its row's upstreamability (affine-83p)"
```

---

### Task 8: Backward compatibility fixture, then document the column

**Files:**

- Modify: `scripts/woven-patch-manifest.md`
- Test: `scripts/woven-manifest-guard.test.sh`

- [ ] **Step 1: Write the backward-compatibility test**

This must be written **before** the manifest gains the column, and it must keep passing afterwards — it is the guarantee that a four-column manifest still parses.

```bash
# --- 24. a manifest with NO State column still parses as all-PRESENT ---------
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
```

- [ ] **Step 2: Run it**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: `✔ exit 0`. It should already pass — Task 1 made absent-column mean PRESENT. If it fails, the `n >= 6` guard in the parser is wrong.

- [ ] **Step 3: Add the column to the live manifest**

In `scripts/woven-patch-manifest.md`, add a `State` header cell and separator cell to the `## Diverged upstream-owned files` table, and an empty fifth cell to each of the three existing rows. Empty normalises to PRESENT, so behaviour is unchanged:

```markdown
| File | Category | Why | Delete when | State |
| ---- | -------- | --- | ----------- | ----- |
```

- [ ] **Step 4: Document the vocabulary in the legend**

Below the existing Category legend table near the top of the file, add:

```markdown
| State                | Meaning                                                                               |
| -------------------- | ------------------------------------------------------------------------------------- |
| _(empty)_            | The file is present in the tree and diverges from upstream. The default.              |
| **REMOVED**          | This fork deletes the upstream-owned file. The row stays; absence is the declaration. |
| **MOVED** `new/path` | This fork relocates it. The destination is checked, and inherits the row's category.  |

A deletion or rename is still a divergence — arguably the most rebase-dangerous
kind, because an upstream edit to a file the fork deleted resurrects it on the
next merge. Declare it here rather than dropping the row (`affine-83p`).
```

- [ ] **Step 5: Run the full suite**

Run: `scripts/woven-manifest-guard.test.sh`
Expected: every fixture `✔`, `rc=0` — including fixture 24, which now proves compatibility against a shape the live manifest no longer has.

- [ ] **Step 6: Verify the guard is green on the real tree in both directions**

```bash
scripts/woven-manifest-guard.sh --head HEAD; echo "inbound rc=$?"
```

Expected: `rc=0`, `✔ every upstream-owned divergence is manifested, and every row resolves.`

- [ ] **Step 7: Commit**

```bash
micromamba run -n affine git commit -m "docs(woven): document the State column in the patch manifest (affine-83p)"
```

---

## Done when

- `scripts/woven-manifest-guard.test.sh` is green, with fixtures 18–28 added.
- Deleting an upstream-owned file has a reachable green state inbound (fixture 19). The outbound-side proof — a REMOVED FORK-LOCAL row is still blocked, a REMOVED ADDITIVE row is still sendable — is Task 7's work and has not landed as of Task 6.
- Renaming one has a reachable green state inbound and is still caught outbound at its destination (fixtures 23, 26).
- `STALE` names both causes and neither prescription produces the opposite failure (fixture 22).
- The outbound `STALE` gate is unchanged, as `affine-83p` requires.
- `bd close affine-83p` with a reason naming the fixtures that prove each acceptance criterion.
