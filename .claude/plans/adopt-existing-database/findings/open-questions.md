# Open questions — adopt-existing-database

Two questions remain open (OQ-3, OQ-4), both scope decisions that can be deferred without
rework. OQ-1 and OQ-2 were resolved by the operator on 2026-09-01; their reasoning is kept below
rather than deleted, because both encode a constraint an implementer must respect.

## OQ-1 — RESOLVED 2026-09-01: yes, one boot-only bypass — `AFFINE_DB_COMPAT_SKIP=1`

Accepted as recommended; recorded as **D11**. Binding constraints for T5: the bypass skips the
**boot guard only, never the predeploy gate**; it logs at **ERROR on every boot** naming the
verdict it suppressed; and it is documented as an incident tool, not a configuration option, and
is not rendered by the chart. Original reasoning below.

A guard that refuses to boot is, by construction, a way to take the fleet down. The DB_AHEAD and
`IDENTITY_MISMATCH` verdicts are conclusive enough that refusing is right — but if the guard
itself has a bug (a mis-resolved migrations directory, a stamp written with the wrong id), there
is no way to start the server to fix it. The argument against is real: an escape hatch is the
thing that gets left on. The per-boot ERROR log is what makes it acceptable, and the predeploy
gate remains unbypassable.

## OQ-2 — RESOLVED 2026-09-01: the verification splits; only the CNPG drill waits for T6

Accepted; recorded as **D12**. The **local half comes forward into T3/T4** — the ava suite
asserts verdicts against a database carrying a real `_prisma_migrations` history (not only
synthetic sets), plus a local rehearsal path that loads a dump into scratch Postgres and runs
`db status` / `db check`. That is the capability the deleted `woven-migration-rehearsal.sh`
approximated and the bead's item 2 calls homeless, and it removes most of T6's risk without a
cluster.

Only the **CNPG cluster drill** remains in T6, deliberately later rather than merely deferred:
the runbook's measured timings make it a real cost, so it should be spent once on shipped
behaviour; and the remaining sub-question below cannot be answered well until the command exists
and its exact invocation and output are known.

**Verified not to be a discovery risk:** the runbook
(`infrastructure/docs/src/operations/affine-pg-restore-drill.md`, bead `infra-zptb.6`) exists and
is thorough — 268 lines, a parameterised procedure, measured timings, a three-way discrimination
section, a negative control, and a traps section. It recovers into a scratch cluster in the
`agents` namespace.

**Still open inside T6 (needs an infra-repo owner):**

Whether T6 reuses the `infra-zptb.6` drill procedure as-is against a fresh scratch restore, or
whether the drill runbook itself gains a step ("bring a server up against the restored database
and record the verdict"), which would make this a cross-repo deliverable with an infra-side bead.
The second is more useful long-term — the drill currently proves the _data_ restores but not that
a _server may adopt it_, which is precisely the gap the bead names.

The bead's acceptance criteria ends "Verified against a database recovered per the infra
restore-drill runbook", so a CNPG restore into a scratch cluster is the one part of this work
needing an environment outside this repo.

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
