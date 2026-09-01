# Open questions — adopt-existing-database

Four questions remain. **None blocks T1–T3**, which are pure-core and DB-state work. OQ-1 must
be settled before T5 (enforcement) ships; OQ-2 is T6's precondition; OQ-3 and OQ-4 are scope
decisions that can be deferred without rework.

## OQ-1 — Does the boot guard need an emergency bypass? (settle before T5)

A guard that refuses to boot is, by construction, a way to take the fleet down. The DB_AHEAD and
`IDENTITY_MISMATCH` verdicts are conclusive enough that refusing is right — but if the guard
itself has a bug (a mis-resolved migrations directory, a stamp written with the wrong id), there
is no way to start the server to fix it.

**Recommendation: yes, one env-only bypass — `AFFINE_DB_COMPAT_SKIP=1`** — with these properties:

- It skips the **boot** guard only, never the predeploy gate. The gate is where the mutation
  happens and it is already safe to wedge.
- It logs at ERROR on every boot, naming the verdict it suppressed, so a bypass left on is
  visible in logs rather than silent.
- It is documented as an incident tool, not a configuration option, and not rendered by the
  chart — an operator sets it deliberately via `extraEnv`.

The argument against is real: an escape hatch is the thing that gets left on. The logging
requirement is what makes it acceptable, and the predeploy gate remains unbypassable.

## OQ-2 — Who runs the restore-drill verification, and against what? (T6 precondition)

The bead's acceptance criteria ends "Verified against a database recovered per the infra
restore-drill runbook" (`infrastructure/docs/src/operations/affine-pg-restore-drill.md`,
bead `infra-zptb.6`). That is the only part of this work needing an environment outside this
repo — a CNPG restore into a scratch cluster.

Open: whether T6 reuses the `infra-zptb.6` drill procedure as-is against a fresh scratch
restore, or whether the drill runbook itself gains a step ("bring a server up against the
restored database and record the verdict"), which would make this a cross-repo deliverable with
an infra-side bead. The second is more useful long-term — the drill currently proves the _data_
restores but not that a _server may adopt it_, which is precisely the gap the bead names — but it
needs an infra-repo owner.

## OQ-3 — Should `db status` gate CI on PRs that add a BLOCKING migration?

`db status --json` makes it mechanical to fail (or annotate) a PR that introduces a `BLOCKING`
migration, which would surface the rollback cost at review time rather than at merge time. This
is a natural companion to the merge-checklist rewire in T6.

Deferred deliberately: it needs a database in CI to compute _pending_ (a comparison against an
applied set), or a variant that classifies **all migrations added by the diff** without a
database. The latter is probably the right shape — a pure-static PR check over
`git diff --name-only` restricted to `migrations/`, reusing `classify.ts` with no DB at all — but
it is additive to this plan, not part of it. File as a separate bead if wanted.

## OQ-4 — Should data migrations be classified too?

The bead's spec is about prisma migrations, and this plan classifies only those. Data migrations
(`_data_migrations`, driven by `src/data/commands/run.ts`) differ in a way that matters: each
carries a `down()`, so they are revertible **by design** in a way prisma migrations are not.

But `down()` being present is not the same as `down()` restoring data — a migration that
`DELETE`s rows cannot un-delete them, and the deleted rehearsal script scanned the TS sources for
`DELETE FROM|TRUNCATE|DROP TABLE|DROP COLUMN` for exactly that reason.

**Recommendation:** have `db status` **list** pending data migrations (name, and whether `down()`
is a no-op) without tiering or gating them, and leave the semantic guarantee where the prior art
put it — a dynamic row-count comparison across a rehearsal, not a static scan. Listing is cheap
and closes the "what will this deploy actually do" question the report is for. Gating them is a
larger question about whether `down()` is trustworthy, and belongs in its own bead.

## Resolved during design

- **Is `app_configs` safe for an identity stamp?** Initially assumed yes on the strength of the
  `signing-key.ts` precedent; then found that `loadDbOverrides()` merges every row into the
  runtime config tree behind a one-entry denylist; then resolved yes after all, because
  `override()` ignores unknown config modules — so a `$`-prefixed id is inert. See G3, D6.
- **Would the infra `prune-app-configs.sh` Job delete the stamp?** No. Its scope is explicitly
  narrow (only ids in `GIT_OWNED_KEYS`) and commented as never to become a wipe. See G3.
- **Does a throw in `onApplicationBootstrap` actually prevent listening?** Yes, verified in the
  installed `@nestjs/core`. See G4.
- **Does the pending-migration scan need a reviewed-exception file?** Not yet — measured zero
  false positives across 117 migrations. See G2, D4.
- **Must the predeploy gate be implemented in the infrastructure repo?** No. The chart already
  invokes `self-host-predeploy.js` from this repo. See G1.
