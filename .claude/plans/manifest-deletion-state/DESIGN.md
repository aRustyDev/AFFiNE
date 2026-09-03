# Declarable removal in the patch manifest — design

Bead: **affine-83p** · discovered from **affine-hn1.4** · engine `scripts/woven-manifest-guard.sh`
Date: 2026-09-01 · Status: approved, pending implementation plan

## Problem

The manifest can say _"this upstream-owned file diverges."_ It cannot say _"this
upstream-owned file diverges by not existing."_ So when the fork deletes or
renames a file that exists at the upstream baseline, no manifest state clears
the guard, and the two failure messages prescribe opposite fixes.

Measured on `woven/main` @ `ca96cc38cd`, deleting
`packages/backend/server/src/plugins/oauth/providers/oidc.ts`:

| manifest state | inbound                                           | outbound                                      |
| -------------- | ------------------------------------------------- | --------------------------------------------- |
| row kept       | rc 1 STALE — _"Drop the row, or repoint it"_      | rc 1 STALE — _"Update or drop the row"_       |
| row dropped    | rc 1 UNMANIFESTED — _"add a row to the manifest"_ | rc 1 UNMANIFESTED — _"Add a row — or revert"_ |

Keep the row and you are told to drop it. Drop it and you are told to add it.
The same cycle appears for a rename with the row repointed at the destination:
rc 1 UNMANIFESTED on the now-absent source.

It **fails closed**, so this is not a leak. But the prescribed remediation is
unachievable, and the operator is told to do the thing they just did.

### Root cause

`path_present()` is one predicate carrying four distinct meanings. "Not present"
can mean:

1. upstream deleted it → drop the row
2. **the fork deleted it** → the row must _stay_
3. a rename moved it → repoint the row
4. the row is a typo → fix the row

`STALE` collapses all four into _"upstream probably deleted or renamed it."_ But
case 2 is a diff against the baseline, so dropping the row hands the path
straight to `comm -23` and it returns as `UNMANIFESTED`.

### Scope is wider than fork-local patches

`STALE` is computed over **all** manifest rows, not only FORK-LOCAL CORE PATCH
ones. Deleting the ADDITIVE `packages/backend/server/src/seed/index.ts`
deadlocks identically. This is a defect in the row-to-tree correspondence
itself, not in the leak policy layered on top of it.

### A fork deletion is not a case to waive

Deleting an upstream-owned file is among the most rebase-dangerous divergences
there is: delete it, let upstream edit it later, and the next merge resurrects
it silently. The fix must keep the deletion **declared**, not exempt it.

## Provenance

The cycle pre-dates `affine-hn1.4` on the inbound side. `affine-hn1.4` extended
it to outbound by gating the outbound verdict on `STALE` — the correct fix for a
demonstrated leak, where a rename made outbound report "safe to send upstream"
while the patch was fully present. That gate is what makes a rename fail closed,
so this design **does not touch it**. See
`.claude/plans/upstream-leak-guard/DESIGN.md`, _"Outbound is an ADDITIONAL
question, not a separate one"_.

Found by code review of `affine-hn1.4` task 3.

## Decision: State is an orthogonal column, not a third category

A third category (`FORK-LOCAL DELETION`) was considered and rejected.

`Category` answers one question: **is this divergence upstreamable?** A deletion
still has an upstreamability — dropping the ADDITIVE `seed/index.ts` is a
coherent thing to send upstream; dropping `oidc.ts` is not. A third category
makes that axis unstateable and forces the outbound gate to hardcode a deletion
policy.

An orthogonal fifth column keeps the two axes separate, and the outbound
question then answers itself with **no change to the outbound gate**:

- a REMOVED **FORK-LOCAL** row still classifies as `FORK-LOCAL CORE PATCH`, so
  it stays in `FORKLOCAL`; a deleted path still appears in `CHANGED`; outbound
  blocks it. Correct — that branch would delete a file from upstream.
- a REMOVED **ADDITIVE** row is absent from `FORKLOCAL`, so outbound stays
  clean. Correct — "the fork drops its own additive change" is a sendable diff.

Deletion inherits the existing vocabulary rather than needing a new policy. Given
that the bead forbids weakening the outbound gate, a design that leaves it
untouched is the safest available shape.

**Correction, post-review:** "no change to the outbound gate" is true only of
the LEAKED comparison above — deletion really does inherit Category with no new
leak policy. It was NOT true of the outbound PRE-gate (the refusal to judge
until inbound is clean), which this design's own new verdicts — RESURRECTED,
OBSOLETE, MOVED_GONE — needed adding to and, for one commit, were not. See
"Post-review correction" below.

### Vocabulary

The `## Diverged upstream-owned files` table gains a `State` column, normalised
exactly as `Category` already is — strip `*`, `_`, `` ` ``, trim, then compare as
an exact field under `LC_ALL=C`.

**It is appended as the last (fifth) column, not inserted after `Category`.**
The parser reads the path from awk field `f[2]` and the category from `f[3]`;
inserting `State` at column 3 would shift `Category` to `f[4]` and rewrite every
existing row. Appending makes the parser change purely additive — read `f[6]`
when present — which is what lets the three existing rows stay untouched.
Readability loses slightly to migration safety here.

| value                   | meaning                                                                 |
| ----------------------- | ----------------------------------------------------------------------- |
| empty, or column absent | `PRESENT` — the file exists and diverges. Today's semantics.            |
| `REMOVED`               | the fork deletes this upstream-owned file.                              |
| ``MOVED `new/path` ``   | the fork relocates it; destination is the cell's first backticked path. |
| anything else           | **exit 2** (`BADSTATE`), mirroring `BADCAT`. Never defaults to REMOVED. |

Defaulting a missing State to `PRESENT` is the fail-closed choice: `PRESENT` is
the **stricter** reading, because under it absence is a failure. The three
existing rows therefore need no edit and every current fixture keeps passing
byte-identically. Migration risk is zero.

## The verdicts

`path_present()` becomes State-aware — one predicate becomes a small table.

| State           | at baseline | at HEAD     | verdict                                 |
| --------------- | ----------- | ----------- | --------------------------------------- |
| PRESENT         | —           | present     | unchanged (`UNDIVERGED` check as today) |
| PRESENT         | —           | absent      | **STALE**                               |
| REMOVED / MOVED | present     | absent      | ✓ source side satisfied                 |
| REMOVED / MOVED | present     | **present** | **RESURRECTED** — new                   |
| REMOVED / MOVED | **absent**  | absent      | **OBSOLETE** — new                      |

`MOVED` shares every source-side verdict with `REMOVED` — the source path is
gone in both cases, and the reasons it might wrongly be present or wrongly be
absent-at-baseline are identical. `MOVED` then adds the destination assertions
below. Treating them as one predicate with an optional second half keeps a
single code path for the source side.

`RESURRECTED` is a safety property the guard does not have today: an upstream
merge restoring a file the fork deleted is currently silent. `OBSOLETE` is the
post-sync case where upstream deleted the file too, so the row has nothing left
to describe.

`STALE` becomes provably accurate. It can now fire only on a `PRESENT` row,
because a fork deletion is declared, so absence really does implicate upstream or
a typo. Its message names both remaining causes and both achievable fixes:

- upstream deleted or renamed it → drop the row, or repoint it
- **this branch deleted it → set `State` to `REMOVED`**

That is the acceptance criterion discharged directly: the message distinguishes
"absent because this branch deleted it" from "absent because upstream deleted
it", and neither prescription produces the opposite failure.

One window remains where "drop the row, or repoint it" is only conditionally
safe: `UPSTREAM_OWNED` is computed from baseline existence, so until
`scripts/woven-upstream-baseline` is re-pointed past the upstream deletion, the
path is still in the baseline and dropping the row bounces to `UNMANIFESTED`.
The merge checklist already sequences the baseline re-point before the guard
is consulted, so a finished merge commit — the only thing CI ever sees — never
lands in this window; it is reachable only by hand, mid-merge. The message now
says so explicitly, and even there it is self-correcting: `UNMANIFESTED`'s own
message says exactly what is still missing.

### Why the deadlock breaks

`MANIFESTED` still contains a REMOVED row's path, so `comm -23` never sees it
and **`UNMANIFESTED` needs no change at all**. The cycle breaks solely because
keeping the row stops producing `STALE`. Both halves of the four-cell table
resolve through the same one-line manifest edit.

## Renames

A `MOVED` row asserts three things:

1. the source path is absent at HEAD (as REMOVED)
2. the destination path is present at HEAD
3. **the destination joins the outbound `FORKLOCAL` set when the row's category
   is `FORK-LOCAL CORE PATCH`**

Clause 3 is load-bearing, and it is the only genuinely new outbound logic in
this design. Without it, fixing the deadlock reintroduces the very leak
`--no-renames` exists to prevent, by a different route: the rename now reaches
green, and the destination — absent at the baseline — is fork-owned, so it falls
outside `UPSTREAM_OWNED` and outbound goes blind to a fully-present relocated
patch. The `upstream-leak-guard` design records that failure as _"not
hypothetical."_ With clause 3, outbound is strictly stronger than it is today.

**Corrected below:** that was true when this section was written, and stopped
being true once "Post-review correction: the outbound pre-gate must track
every inbound verdict" landed. Once the pre-gate refuses to judge on
`INBOUND_UNCLEAN`, `print $4` no longer changes any exit code — RESURRECTED,
LEAKED (via the source path alone) or OBSOLETE already catch every case clause
3 used to. What's load-bearing now is the pre-gate; clause 3 only makes the
leak report name the destination too. See that section below for the case
split.

The destination needs no row of its own. That keeps it out of `UNDIVERGED`,
whose branch only runs when a row's path exists, and avoids relaxing the table's
"upstream-owned" framing.

**Alternative considered and rejected:** two rows — a REMOVED row for the source
plus an ordinary row for the destination. This would require the table to accept
fork-owned paths, and would fire `UNDIVERGED` spuriously on every such row.

## Fail closed

- an unrecognised `State` exits **2**. It is a broken manifest, not a policy
  violation, and guessing "probably PRESENT" for a typo'd `REMOVED` would let a
  genuine stale row pass as a declared deletion.
- `MOVED` with no parsable destination exits **2**.
- a `MOVED` destination absent from the tree is rc **1**.
- the destination path is compared under the same byte-literal rules the engine
  already pins: `--no-renames`, `-c core.quotePath=false`, `LC_ALL=C`. A
  destination that C-quotes or collates away would drop out of the outbound set,
  which is clause 3 failing open.
- `--dump-rows` prints `path<TAB>category<TAB>state<TAB>destination`
  (destination empty unless `MOVED`), so the list the guard acts on remains the
  list an operator can inspect — the existing rule from `affine-hn1.4` task 3.
- a destination path present with a State other than `MOVED` exits **2**. It
  means the cell was half-edited, and silently ignoring the path is how clause 3
  stops applying without anyone noticing.

## Testing

Eleven fixtures in `scripts/woven-manifest-guard.test.sh`, each asserting an exit
code **and** the named paths, so a crashing guard cannot satisfy a "must fail"
case vacuously.

| #   | fixture                                  | expected                        |
| --- | ---------------------------------------- | ------------------------------- |
| 1   | delete `oidc.ts`, State=REMOVED, inbound | rc 0 — the deadlock, green      |
| 2   | same, outbound                           | rc 1, names `oidc.ts`           |
| 3   | delete `seed/index.ts`, State=REMOVED    | rc 0 inbound, rc 0 outbound     |
| 4   | State=REMOVED but file present           | rc 1 RESURRECTED                |
| 5   | State=REMOVED, path absent at baseline   | rc 1 OBSOLETE                   |
| 6   | PRESENT row, file deleted, undeclared    | rc 1 STALE, both causes named   |
| 7   | MOVED, source gone + destination present | rc 0 inbound                    |
| 7b  | MOVED, destination absent from the tree  | rc 1                            |
| 8   | **MOVED, FORK-LOCAL, outbound**          | **rc 1, names the DESTINATION** |
| 9   | State=`REMOVEDD`                         | rc 2                            |
| 10  | existing three rows, no State column     | every current fixture unchanged |

Fixture 8 is the one that matters most: it is the only test that proves the
rename hole of clause 3 stayed shut. Fixture 10 is the migration guarantee.

**Corrected below:** same stale framing as "Renames" above — see "Post-review
correction: the outbound pre-gate must track every inbound verdict". What
fixture 8 actually pins is that `FORKLOCAL`'s clause 3 still names the
destination in the leak report; the rename hole itself is kept shut by
`INBOUND_UNCLEAN`, not by this fixture. As landed, fixture 8 is fixture 26 in
`scripts/woven-manifest-guard.test.sh` (this table keeps the original plan's
numbering — see the numbering note under File Structure).

## Non-goals

- The outbound `STALE` gate is untouched. The bead forbids resolving this by
  dropping it. **Corrected below:** untouched turned out to mean "not
  rewritten", not "not extended" — the pre-gate this bullet refers to needed
  RESURRECTED, OBSOLETE and MOVED_GONE added to what it consults, and for one
  commit wasn't. See "Post-review correction" below.
- `UNMANIFESTED` logic is unchanged.
- No second manifest section and no second section-scoping rule in the parser —
  `affine-hn1.4` established one parser with one scoping rule, and this design
  keeps it.
- `Delete when` keeps its meaning ("drop this row when") and already reads
  correctly for a REMOVED row.

## Post-review correction: the outbound pre-gate must track every inbound verdict

A code review after this design shipped found the gap the two notes above
point to. `.claude/plans/upstream-leak-guard/DESIGN.md` ("Outbound is an
ADDITIONAL question, not a separate one") requires outbound to refuse judging
this change set at all unless every inbound check passes — not because the
individual failure modes were enumerated and handled, but so that ANY future
way of breaking the manifest-row-to-tree correspondence fails closed by
construction, anticipated or not. This design added three new ways a row can
break that correspondence — RESURRECTED, OBSOLETE, MOVED_GONE — on top of the
two that existed (UNMANIFESTED, STALE). The outbound pre-gate, at the time,
consulted only the original two. It was never extended to the three this
design introduced.

The consequence: a MOVED row whose declared destination did not match where
the FORK-LOCAL content actually landed (a typo, a stale edit, a row nobody
re-verified) produced MOVED_GONE inbound, correctly. Outbound's pre-gate never
looked at MOVED_GONE, so it fell through to the leak comparison, found the
declared (wrong) destination absent from the diff, and reported "safe to send
upstream" at rc 0 while the real destination carried the whole patch. The two
directions disagreed — the exact thing the upstream-leak-guard design says is
supposed to be impossible.

Fixed in `scripts/woven-manifest-guard.sh` by making the pre-gate consult a
single accumulated `INBOUND_UNCLEAN` flag, set by all five inbound verdicts,
rather than naming checks at the outbound site a second time — the second
enumeration is exactly what let this ship. `UNDIVERGED` stays outside that
flag, as ever: a row for a file that no longer differs cannot hide a patch.

**Invariant, going forward:** any inbound verdict this guard ever grows must
feed `INBOUND_UNCLEAN`. That flag is the only thing outbound's pre-gate
consults, precisely so there is no second enumeration left to forget.

## Related

- `affine-cm9` — the ADDITIVE / FORK-LOCAL CORE PATCH split this column sits beside
- `affine-tpb` — adopt existing seams rather than rebuild; why State reuses the
  `Category` normalisation path and the existing classifier shape
- `.claude/plans/upstream-leak-guard/DESIGN.md` — the outbound half, and the
  byte-literal comparison rules this design inherits
