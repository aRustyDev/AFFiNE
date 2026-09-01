# Upstream leak guard — design

Bead: **affine-hn1.4** · epic **affine-hn1** · strategy **affine-cm9**
Date: 2026-08-31 · Status: approved, pending implementation plan

## Problem

`affine-cm9` splits fork changes into two categories: **ADDITIVE** (rebase-safe,
sometimes upstreamable) and **FORK-LOCAL CORE PATCH** (changes upstream
behaviour; never upstreamed). It requires that CI "block them from
upstream-directed branches/PRs". That has never been built.

`affine-hn1.2` built the inbound half — `scripts/woven-manifest-guard.sh` fails
when an upstream-owned file diverges with no manifest row, so a fork patch
cannot be silently lost to the next upstream merge. This bead is the outbound
half: a fork patch must not reach upstream.

The manifest table already carries the category in column 2, and
`manifest_rows()` already isolates that table and extracts column 1. Nothing
reads the category. This design makes it load-bearing.

### The failure this prevents

Not "pushing to upstream by accident" in general. Specifically: **the day the
fork deliberately contributes something upstream and a fork-local patch rides
along in the branch.**

The fork intends to upstream generic fixes — that is the point of the ADDITIVE
category, and the manifest already nominates a candidate. Of
`.github/workflows/build-test.yml` it says the added `workflow_dispatch` is
"low-conflict on future merges and is a plausible upstream contribution".

Sending that upstream means branching. Branch from `woven/main`, as anyone
would, and the branch also carries
`packages/backend/server/src/plugins/oauth/providers/oidc.ts` — a core auth
patch naming an internal issuer (`id.auth.woven`) and an org-CA trust
arrangement. Opening that PR publishes both, publicly, to a project the fork is
a guest in.

This is not a tooling misconfiguration. It is the ordinary shape of forking: the
working branch descends from everything the fork has ever patched.

### Why now

Two reasons.

1. **The near-miss was real.** `gh pr create` defaulted to the parent repo. The
   `affine-hn1.2` PR failed to reach upstream only because `woven/main` does not
   exist there (`Base ref must be a branch`). The fork's `origin` also carries
   upstream's branch names — `origin/canary` among them — so a PR based on a
   shared name would have gone through. `gh repo set-default aRustyDev/AFFiNE`
   closes that specific hole, but it is per-clone git config — a fresh clone
   starts unprotected, so it is a convenience, not a control.
2. **`affine-vap` is unblocked.** Removing the self-hosted member/seat limit will
   add the second and most sensitive FORK-LOCAL CORE PATCH. The guard should
   exist before that patch does.

## Constraint that shapes the design

**A workflow in this fork cannot gate a PR into `toeverything/AFFiNE`.** For
`pull_request` events GitHub runs workflows from the _base_ repository. A PR
into upstream runs upstream's workflows; `woven-manifest-guard.yml` does not
exist there and never executes.

Consequences:

- Blocking at the upstream PR is unreachable. Enforcement must fire strictly
  earlier.
- "The PR's base repo is upstream" — the most robust signal, and the one the
  bead speculated about — is unavailable to CI. It is available to a local
  pre-push hook, which sees the destination URL directly.

A related note in the `hn1.2` workflow ("a push-triggered guard would never fire
on this fork") describes **upstream's** `build-test.yml`, whose `push:` list
covers only `canary`/`beta`/`stable`/`v*.x`. A new fork-owned workflow may
declare any `push:` branches it likes and fires normally. A push trigger is
available to this design.

## Decision: three layers over one engine

| Layer           | Mechanism                                         | Catches                                                                                      | Fails when                           |
| --------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------ |
| 1. Prevention   | `scripts/woven-upstream-branch.sh`                | the branch never contains a fork-local patch                                                 | the branch is made by hand instead   |
| 2. Interception | `.husky/pre-push`                                 | any push to upstream, **or of an `upstream/**` branch anywhere**                             | `--no-verify`, or hooks not wired up |
| 3. Backstop     | `woven-manifest-guard.yml`, push to `upstream/**` | a hand-made `upstream/**` branch — **not** a prepared one, which does not carry the workflow | the branch prefix is not used        |

Each layer covers the previous layer's failure mode. All three call the same
engine, so there is one definition of "is this a leak".

## The engine — `woven-manifest-guard.sh --outbound`

### Parser change

`manifest_rows()` currently emits the backticked path from column 1 of the
`## Diverged upstream-owned files` table. It changes to emit `path<TAB>category`;
the existing inbound consumer takes field 1. One parser, one section-scoping
rule, no second copy — per `affine-tpb`, adopt existing seams rather than
rebuild.

Category strings arrive markdown-emphasised (`**FORK-LOCAL CORE PATCH**`).
Normalisation strips emphasis characters and surrounding whitespace before
comparison.

### The new check

|          | inbound (existing)                                            | outbound (new)                                                              |
| -------- | ------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Question | does an upstream-owned file diverge with **no** manifest row? | does this change set touch a file whose row says **FORK-LOCAL CORE PATCH**? |
| Base     | `UPSTREAM_COMMIT` from `scripts/woven-upstream-baseline`      | same                                                                        |
| Head     | `HEAD` or `--head REF`                                        | same                                                                        |
| Exit     | 0 clean / 1 violation / 2 environment                         | same                                                                        |

Using the same baseline in both directions is what makes this cheap. A branch
built from `UPSTREAM_COMMIT` shows only what it adds — clean. A branch built
from `woven/main` shows `oidc.ts` as diverged, which is the violation.

Output names every offending path, so the fix is mechanical.

### Outbound is an ADDITIONAL question, not a separate one

**Outbound requires the branch to be inbound-clean first, and only then consults
the FORK-LOCAL list.** This is a correctness requirement, not tidiness.

The outbound answer is derived entirely from the manifest, so anything that
quietly breaks the correspondence between a manifest row and the tree removes a
file from the FORK-LOCAL set — and an empty set is indistinguishable from
"nothing to leak". That correspondence has more failure modes than can be
enumerated:

- **The row will not parse.** Markdown permits more row shapes than a parser can
  be trusted to cover — a missing leading pipe, a `#`-prefixed line mid-table, an
  escaped `\|` in a cell.
- **The row's path no longer exists in the tree.** Renaming a fork-local file
  makes the manifested path stale, and `git diff` reports only the destination,
  so the patch is fully present under a name the manifest does not mention. This
  one is not hypothetical: it was demonstrated producing "safe to send upstream"
  on a branch carrying the whole OIDC patch.

Both are already inbound failures — the first as UNMANIFESTED, the second as a
STALE row. So the fix is not to enumerate the failure modes but to refuse to
answer the outbound question at all unless the inbound checks pass. Any future
way of breaking the row-to-tree correspondence then fails closed by
construction, whether or not anyone anticipated it.

This also means the two checks cannot disagree. A branch cannot be "clean to send
upstream" while carrying a divergence the fork has not declared, or a declaration
that no longer describes the tree.

`UNDIVERGED` rows stay a warning: a row for a file that no longer differs from
upstream is harmless, and is the one mismatch that cannot hide a patch.

### Paths must be compared as literal bytes

Two `git diff` defaults corrupt the comparison, and both fail open:

- **Rename detection** collapses a rename to the destination path, hiding the
  manifested source. Use `--no-renames`.
- **`core.quotePath`** C-quotes non-ASCII paths, so `pkg/café.ts` arrives as
  `pkg/caf\303\251.ts` — matching neither the manifest nor `git cat-file`, which
  drops it out of the upstream-owned set too, defeating the inbound backstop as
  well. Use `-c core.quotePath=false`.

For the same reason the guard pins `LC_ALL=C`: `sort -u` deduplicates by
collation, so under a UTF-8 locale two byte-distinct paths that compare equal
collapse into one — and if the dropped line is the fork-local path, outbound
fails open. It also makes the sorted-order invariant `comm` depends on explicit
rather than incidental.

### Fail closed

A manifest row whose category is neither recognisably `FORK-LOCAL CORE PATCH`
nor `ADDITIVE` exits **2**. It is never treated as ADDITIVE by default. A typo
in the manifest must not silently open the gate; this is the one place a parsing
bug would be both invisible and catastrophic.

### No override

The inbound guard downgrades harmless staleness to a warning. The outbound guard
has no escape hatch: exit 1 is final. "Never upstream" is the entire rule. A
legitimate change of category is an edit to the manifest in a reviewed commit,
not a runtime flag.

## Layer 1 — `scripts/woven-upstream-branch.sh`

Creates an upstream-bound branch **from `UPSTREAM_COMMIT`**, not from
`woven/main`, and carries over only the files named on the command line. The
resulting branch cannot contain a fork-local patch because it never descended
from anything carrying one — prevention by construction rather than detection
after the fact.

Behaviour:

- Names the branch `upstream/<name>`. This is what makes layer 3's convention
  reliable: the prefix CI keys on becomes a byproduct of using the tool rather
  than something a person must remember.
- Refuses, before creating anything, if a named file's manifest row says
  FORK-LOCAL CORE PATCH.
- Runs `--outbound` against the finished branch and reports the result, so the
  tool proves its own output rather than asserting it.
- Refuses to run on a dirty tree. This is **not** the convention elsewhere in the
  `woven-*` scripts — the guard deliberately folds uncommitted work in, on the
  grounds that a check which only ever sees `HEAD` reports "clean" on the very
  change you are about to push. The preparer is the opposite case: it takes file
  contents from a **ref**, so an uncommitted edit would silently not be carried
  and the branch would not contain what the operator just looked at. Refusing is
  the honest response to that, not a house style.

**The branch is a starting point, not a finished contribution.** The developer
reviews and adjusts it before pushing — cherry-picking further commits, editing
files, squashing. Both file-picking (this script) and cherry-picking will be used
in practice, and the script deliberately does not try to cover both: it gets you
a correctly-based branch to work from.

This means layer 1's guarantee is **not durable**. A cherry-pick from
`woven/main` after the branch is created can reintroduce a fork-local patch, and
the clean `--outbound` result the script reported at creation time no longer
describes the branch being pushed. Layers 2 and 3 are therefore load-bearing
rather than redundant: they re-check at the moment of push, and on every push to
`upstream/**`, which is the only point at which the branch's final content is
known.

## Layer 2 — `.husky/pre-push`

Pre-push receives the remote name and URL on argv. If the destination URL
identifies the upstream repository, the hook runs the guard and refuses the push
on exit 1.

Two decisions:

- **Match on the destination URL, not the remote's name.** A remote called
  `upstream` proves nothing, and a second remote pointing at the same place
  would bypass a name check. The upstream identity is currently recorded nowhere
  — `scripts/woven-upstream-baseline` pins the commit and tag, not the
  repository — so this design adds `UPSTREAM_REPO=toeverything/AFFiNE` to that
  file. The identity then has one home, consistent with how the baseline commit
  is already treated.
- **Guard the branch tip against the baseline, not the pushed range.** Pre-push
  supplies `<local ref> <local sha> <remote ref> <remote sha>` on stdin, and
  `remote sha` is all-zeros for a branch the remote has not seen. Comparing the
  tip to `UPSTREAM_COMMIT` is the comparison the engine already makes and avoids
  that edge case entirely.

**The hook also fires on branch-name intent, not only on destination.** A branch
named `upstream/**` declares where it is headed, so pushing one _anywhere_ runs
the guard. This is not belt-and-braces; it is the only thing covering the most
likely real flow. Nobody pushes straight to `toeverything/AFFiNE` — they
`git push origin upstream/foo` and open a cross-fork PR, and on that push the
destination is the fork, so a destination-only check exits 0. See "Why layer 3
cannot cover the prepared branch" below for why layer 2 has to carry this.

The hook is a seatbelt, not a lock: `git push --no-verify` walks past it. That is
accepted.

### Why layer 3 cannot cover the prepared branch

**For `push` events GitHub reads the workflow definition from the pushed
commit.** A branch built by `woven-upstream-branch.sh` starts at
`UPSTREAM_COMMIT` and carries only the files you name, so it contains neither
`.github/workflows/woven-manifest-guard.yml` nor `scripts/woven-manifest-guard.sh`
— neither exists at the baseline. Pushing such a branch produces **no workflow
run at all**. Not a red one. None.

So layer 3 fires only on an `upstream/**` branch that descends from `woven/main`
— a hand-made branch, which is the case layer 1 exists to eliminate.

Walk the scenario this design names as layer 3's reason for existing: prepare a
clean branch with the tool, then `git cherry-pick` a commit from `woven/main`
that touches `oidc.ts`. Layer 1's verdict is stale by construction. Layer 2, if
it keyed only on destination, sees a push to the fork and allows it. Layer 3 does
not exist on that ref. Three layers, zero checks.

That is why layer 2 keys on the branch name as well. Push time is the last moment
the code is still on the developer's machine and the only point where every
prepared branch is observable.

**What each layer actually covers, stated honestly:**

|             | prepared branch (`woven-upstream-branch.sh`)       | hand-made branch off `woven/main`   |
| ----------- | -------------------------------------------------- | ----------------------------------- |
| 1. preparer | clean at creation; stale after any later commit    | not involved                        |
| 2. pre-push | **covers it** — via the `upstream/**` name         | covers it — via name or destination |
| 3. CI       | **cannot run** — the workflow is not on the branch | covers it                           |

Layer 3 is therefore the backstop for the _hand-made_ case, not for the prepared
one. Carrying the guard into the prepared branch would fix that, but the files
would then appear in the upstream PR — which is precisely what this whole design
exists to prevent.

## Layer 3 — `woven-manifest-guard.yml`

Extend the existing workflow rather than add a second one. It already runs both
fixture suites; two workflows running overlapping fixtures would drift.

- Existing trigger, unchanged: `pull_request:` into `woven/main` → inbound guard.
- New trigger: `push:` to `upstream/**` → outbound guard.
- `fetch-depth: 0` is required for both, for the same reason: the baseline is
  reachable only as a merge parent, and a shallow checkout cannot resolve it.

CI keys on the branch prefix because it has no other signal available — see the
constraint above. The prefix is weak on its own (it can be forgotten) and is
backed by layers 1 and 2.

## Testing

Fixtures follow the established style: derived from real fork history rather
than synthesised, built with `git commit-tree` plumbing so they never touch the
working tree or the branch, with `GIT_AUTHOR_*` / `GIT_COMMITTER_*` set
explicitly — a runner has no git identity, and the omission previously surfaced
as a confusing exit 2 rather than a test failure.

Added to `scripts/woven-manifest-guard.test.sh`:

- **Known-good outbound** — a branch from the baseline carrying only
  `build-test.yml` (the manifest's own nominated upstream candidate) → exit 0.
- **The leak** — a branch at `woven/main`'s tip → exit 1, naming `oidc.ts`.
- **Category discrimination** — `seed/index.ts` and `build-test.yml` are
  ADDITIVE and must not trip the guard; only the FORK-LOCAL row does. This is
  the fixture that catches a parser reading the wrong column.
- **Fail closed** — a row with an unrecognised category → exit 2.
- **Inbound unchanged** — the existing 13 assertions must still pass, proving
  the shared parser change did not alter inbound behaviour.

New `scripts/woven-upstream-branch.test.sh`:

- A prepared branch passes `--outbound`.
- The branch is named `upstream/**`.
- Naming a FORK-LOCAL file is refused before the branch is created.

New hook coverage: invoke `.husky/pre-push` directly with a synthetic upstream
URL (must fail) and a synthetic fork URL (must pass), asserting both directions
without performing a real push.

## Risks and open items

**Layer 2 runs only where git hooks are wired up.** A hook is per-checkout and
`git push --no-verify` bypasses it, so layer 2 cannot be the only control. That
is what layer 3 is for. The hook itself takes no dependency beyond git, so it
works in a checkout with nothing installed, and its fixtures invoke it directly
rather than through git so its coverage never depends on the wiring.

**Layer 3 depends on a naming convention.** If an upstream-bound branch is made
by hand without the `upstream/` prefix, CI does not fire. Layer 2 covers that
case; layer 1 makes the prefix automatic when used.

**The guard is only as good as the category column.** `affine-vap` must land its
row marked `FORK-LOCAL CORE PATCH`. The inbound guard already forces a row to
exist; this design is what gives the category teeth. Record this on `affine-vap`
so its implementer knows.

## Out of scope

- Changing how `gh` resolves the default repository. Already addressed by
  `gh repo set-default`.
- Any check running in upstream's Actions context. Not reachable.
- Repairing the worktree hooks configuration.
- Adding or recategorising manifest rows. This design reads the column; it does
  not curate it.

## Success criteria

1. `woven-manifest-guard.sh --outbound` exits 1 and names the file when a change
   set touches a FORK-LOCAL CORE PATCH, 0 when it does not, and 2 when a
   category cannot be parsed.
2. The existing inbound assertions still pass unchanged.
3. `woven-upstream-branch.sh` produces a branch that passes `--outbound`, named
   `upstream/**`.
4. `.husky/pre-push` refuses a push whose destination is `UPSTREAM_REPO` and a
   branch carrying a fork-local patch, and permits one whose destination is the
   fork.
5. The guard workflow runs the outbound check on push to `upstream/**` and the
   inbound check on PRs into `woven/main`, both with `fetch-depth: 0`.
