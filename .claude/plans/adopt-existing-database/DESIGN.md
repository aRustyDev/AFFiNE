# PLAN — adopt-existing-database (compatibility check, ADOPT mode, dry-run, deployment identity)

> **FORK-LOCAL. Additive; the guard core is fork-owned (`src/core/db-compat/`), with three
> ADDITIVE rows added to `scripts/woven-patch-manifest.md` for the upstream-owned files it
> wires into. Per `affine-cm9` (fork strategy) and `affine-hn1` (upstream-leak guard).**
> Status: **DESIGN APPROVED 2026-08-31. Implementation in progress — T1 and T2 landed
> 2026-09-01; T3 in review, T4–T6 outstanding.** Design changes made during implementation are
> recorded as D4a/D4b (T1 review), D15/D16 (T2 review) and **D17–D20 (T3 review, including a
> showstopper: the gate crashed on every fresh install)**. The verdict table and wiring below
> reflect them.
> Bead: `affine-tc6` (P1, open, owner adam). Subtasks `.1`–`.6` = T1–T6 below, to be filed.
> Cross-refs: infra beads `infra-zptb.6` (restore drill), `infra-zptb.8` (decommission).
> Decisions: [findings/decision-log.md](findings/decision-log.md) · Grounding:
> [findings/grounding.md](findings/grounding.md) · Open questions:
> [findings/open-questions.md](findings/open-questions.md)

## One-paragraph summary

Today a server instance assumes it either owns a virgin database or one it migrated itself.
`server.initialized()` is literally `models.user.count() > 0`, so a restored or relocated
database is adopted **implicitly**, with no compatibility check — and because deployment is
forward-only, starting an older binary against a database migrated by a newer one fails at
request time rather than at boot. This plan adds a **startup compatibility check** that
classifies the database as EQUAL / DB_BEHIND / DB_AHEAD / DIVERGED and **fails closed on
DB_AHEAD**, an **explicit ADOPT decision** recorded in the database rather than inferred from
user count, a **dry-run report** (`yarn cli db status`) that lists pending migrations tiered
by whether they make rollback impossible, and a **deployment-identity stamp** so pointing a
server at the _wrong_ populated database is detected instead of half-migrated.

## Documents

| Doc                                                      | What                                                                                                                                      |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| [findings/grounding.md](findings/grounding.md)           | Verified facts, all measured on this tree: deployment topology, migration-corpus scan, `app_configs` namespace hazard, Nest boot ordering |
| [findings/decision-log.md](findings/decision-log.md)     | D1–D20, plus D4a and D4b                                                                                                                  |
| [findings/open-questions.md](findings/open-questions.md) | OQ-1, OQ-2 resolved 2026-09-01; OQ-3 (CI gating) and OQ-4 (data migrations) open                                                          |
| [PLAN.md](PLAN.md)                                       | The task-by-task implementation plan derived from this design                                                                             |

## Why the enforcement point is what it is

The consuming deployment (`infrastructure/products/affine/kube/charts/affine`) runs prisma
migrations as an **initContainer in the server pod**, not a Helm hook Job — a deliberate
choice, documented in the template: a pre-install hook deadlocks umbrella installs because it
needs postgres, a regular resource of the same release. Its command is
`node ./scripts/self-host-predeploy.js`, and the upstream self-host compose path runs the
identical command.

Three consequences shape this design:

1. **The gate lands in this repo.** The chart already invokes the script that carries it, so
   there is **no infra-repo change** for the gate itself. (Setting `AFFINE_DEPLOYMENT_ID`
   later is a values-only change via the chart's existing `extraEnv` — no template edit.)
2. **It runs on every pod start**, restarts and scale-ups included — unlike a Helm hook.
3. **Refusal is a safe failure.** The new pod wedges in `Init`, the rolling update stalls, and
   the old fleet keeps serving.

## Architecture

New **fork-owned** directory `packages/backend/server/src/core/db-compat/`. Nothing
upstream-owned lives inside it, so it is rebase-safe by construction and carries no manifest
row. All judgement sits in the two pure modules.

| File               | Purpose                                                                             | Depends on      |
| ------------------ | ----------------------------------------------------------------------------------- | --------------- |
| `classify.ts`      | `classifyDdl(sql) → { tier, hits[] }`. Pattern table only.                          | nothing (pure)  |
| `migration-set.ts` | Resolve the migrations dir; list names, read `migration.sql`.                       | `node:fs`       |
| `db-state.ts`      | `_prisma_migrations` via `$queryRaw`: raw rows, table-absent, populated-or-unknown. | Prisma          |
| `compat.ts`        | Combine set + state + identity into a `CompatReport` + verdict.                     | pure over above |
| `identity.ts`      | Read/write the deployment stamp in `app_configs`.                                   | Prisma          |
| `env.ts`           | The three `process.env` reads, in one place (D13).                                  | nothing         |
| `service.ts`       | `DbCompatService` plus the pure `decide()` adoption gate.                           | above           |
| `guard.ts`         | `OnApplicationBootstrap` → refuse to listen; pure `enforce()`.                      | service         |
| `render.ts`        | Format a `CompatReport` as operator-readable text.                                  | nothing (pure)  |
| `index.ts`         | `DbCompatModule` + `DbCompatGuardModule` + public types (D14).                      | —               |
| `cli-module.ts`    | `DbCompatCliModule` — the config+prisma-only CLI context (D7).                      | —               |

## Verdicts

`DB_AHEAD` detection needs **no identity**: an applied migration name this binary does not
carry is conclusive on its own. That is the guard the bead is really about, and it works from
the first deploy that contains it.

`applied` = rows in `_prisma_migrations` with `rolled_back_at IS NULL`. A row with
`finished_at IS NULL AND rolled_back_at IS NULL` is a failed or interrupted migration and gets
its own verdict rather than being counted either way.

| Verdict             | Meaning                                         | Predeploy                              | Boot                    |
| ------------------- | ----------------------------------------------- | -------------------------------------- | ----------------------- |
| `VIRGIN`            | no `_prisma_migrations`, no users               | proceed                                | proceed                 |
| `EQUAL`             | applied == known                                | proceed                                | proceed                 |
| `DB_BEHIND`         | known ⊃ applied                                 | migrate (subject to the adoption gate) | proceed                 |
| `DB_AHEAD`          | applied ⊃ known                                 | **refuse**                             | **refuse**              |
| `DIVERGED`          | both ahead and behind                           | **refuse**                             | **refuse**              |
| `IDENTITY_MISMATCH` | stamp ≠ configured id, **or stamp unreadable**  | **refuse**                             | **refuse**              |
| `MIGRATION_FAILED`  | a row unfinished and not rolled back            | **refuse**                             | **refuse**              |
| `SCHEMA_INCOMPLETE` | migrations recorded, but a core table is absent | **refuse**                             | **refuse**              |
| `UNREADABLE`        | migrations dir not found                        | **refuse**                             | log ERROR, **continue** |

Precedence, and it is load-bearing — an earlier branch wins:

```
UNREADABLE → MIGRATION_FAILED → IDENTITY_MISMATCH → DIVERGED → DB_AHEAD → SCHEMA_INCOMPLETE → VIRGIN → DB_BEHIND → EQUAL
```

**`SCHEMA_INCOMPLETE` was added during T2**, after code review found a verified fail-open: a
database whose `_prisma_migrations` records applied migrations but whose `users` table is absent
reported `EQUAL` with `rollbackPossible: true` — a clean bill of health for a broken schema. With
both tables absent it reported `VIRGIN`, i.e. "fresh install, proceed", and `migrate deploy` then
collides on `CREATE TABLE`. The root cause was that `populated` was a plain boolean, so "I could
not determine this" was indistinguishable from "empty". `populated` is now `boolean | null`, and:

- `SCHEMA_INCOMPLETE` = `populated === null && hasMigrationsTable` — the schema contradicts itself.
- `VIRGIN` = `!hasMigrationsTable && (populated === false || populated === null)` — null is fine
  here, because a schema with _neither_ table is genuinely empty rather than contradictory.

A partially-restored database is item 3 of the bead, so this is the scenario the work exists for
rather than a hypothetical.

**`rollbackPossible` semantics, also corrected in T2.** The engine classifies only _pending_
migrations; it never classifies what is already applied. So `EQUAL` reports `null` ("the question
does not apply" — nothing is pending) rather than `true`, which would assert rollback safety on
evidence never gathered, in the state the live cluster is normally in. Conversely `VIRGIN` reports
the computed value rather than `null`, because on a fresh install everything _will_ be applied and
"IMPOSSIBLE" is both factual and useful.

`UNREADABLE` is asymmetric on purpose. A predeploy wedge is safe; refusing to _boot_ over a
packaging fault could wedge the fleet for a non-safety reason. Since the initContainer shares
the pod and the image, predeploy has already refused in that case — the boot path never sees
it in the deployment that matters. See D9.

**Mapping to the bead's wording.** The bead specifies four classes, EQUAL / DB_BEHIND /
DB_AHEAD / UNRELATED. The first three keep their names. **`UNRELATED` splits into two verdicts**
because it has two distinguishable causes and they deserve different messages: a _branched
migration history_ (`DIVERGED` — applied and known each contain names the other lacks) and a
_different deployment's database_ (`IDENTITY_MISMATCH` — the stamp names another deployment).
Both refuse. `VIRGIN`, `MIGRATION_FAILED`, `SCHEMA_INCOMPLETE` and `UNREADABLE` are additions: the
bead's four classes tacitly assume a readable, non-empty, self-consistent migration history, and
each of those four needs an answer that is neither "adopt" nor a crash. Nine verdicts total.

## DDL classification (tiers)

Measured by running a prototype of `classify.ts` over all 117 real migrations (G2a). **These are
the numbers T1 asserts:**

```
total=117  BLOCKING=17  DESTRUCTIVE=14  EXPAND=86
```

One tier would not be enough: **8 of the 14 `DESTRUCTIVE` migrations carry `drop-constraint` with
no blocking rule**, and an older binary reads and writes past a dropped foreign key without
noticing. Reporting those eight as "rollback impossible" would be an alarm that cries wolf, and a
gate operators learn to pass with the override flag is not a gate.

These counts were **corrected during T1** from an earlier 18 / 14 / 85: the prototype's extra
`BLOCKING` was a false positive, where `retype-column` matched the quoted column name `"type"`
instead of a real `TYPE` keyword. See the correction note in G2a — the fixture moved because a
false positive was removed, not because the assertion was relaxed.

Matching is **statement-level, dollar-quote-aware, and identifier-aware**, not per-line (D4a). All
three are load-bearing, not defensive: scrubbing `$$`-quoted function bodies removes spurious
`DESTRUCTIVE` verdicts (G2b), scrubbing double-quoted identifiers removes the false `BLOCKING`
above and closes a fail-open where an apostrophe inside an identifier blanked the rest of the file
(G2d), and statement-level matching after whitespace collapse catches a
multi-line `ALTER COLUMN "x"` / `SET NOT NULL` that a per-line scan would miss (G2c).

| Tier          | Meaning                                                 | Patterns (indicative)                                                                                           | Gates?        |
| ------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------- |
| `BLOCKING`    | an older binary cannot read or write                    | `DROP TABLE`, `DROP COLUMN`, `RENAME TO`, `RENAME COLUMN`, `ALTER COLUMN … TYPE`, `ALTER COLUMN … SET NOT NULL` | yes           |
| `DESTRUCTIVE` | data or a constraint is lost; the old binary still runs | `DROP CONSTRAINT`, `DROP INDEX`, `TRUNCATE`, `DELETE FROM`                                                      | no (reported) |
| `EXPAND`      | additive                                                | everything else                                                                                                 | no            |

`BLOCKING` is the tier that answers "will rollback be possible". `db status` reports the answer
as an explicit line, not as something the operator has to infer from a hit list.

## Adoption gate and the identity ratchet

**The gate.** Populated database, no stamp — which is _every_ existing deployment the moment
this ships:

- `EQUAL`, or `DB_BEHIND` where every pending migration is `EXPAND`/`DESTRUCTIVE`
  → **auto-adopt**: write the stamp, log `ADOPTING pre-existing database (implicit)`.
- `DB_BEHIND` with any `BLOCKING` pending migration
  → **refuse** unless `AFFINE_DB_ADOPT=1` or `--adopt`.

The live cluster is `EQUAL`, so shipping the guard does not wedge it, and the explicit gate
sits exactly where the irreversibility is (D3).

**Stated tension with the bead's wording.** The bead asks that adoption be "a decision recorded
in logs rather than an accident of user count". Auto-adoption is still automatic, so a strict
reading is only half-satisfied. What changes regardless of tier is the _basis_: adoption becomes
a recorded, durable stamp naming the version, build, timestamp and mode — never an inference
from `user.count() > 0` — and the auto path is reached only after the compatibility check has
already passed. The always-require-the-flag variant was considered and rejected in D3 on
rollout-safety grounds, not overlooked. If an operator wants the strict form, `AFFINE_DB_ADOPT`
is the existing knob and the gate can be tightened to demand it unconditionally without
redesign.

**The ratchet.** A deployment identity must be asserted from **outside** the database or the
check is circular — an id read _out_ of a database cannot tell you it is the wrong database. So
identity comes from the `AFFINE_DEPLOYMENT_ID` environment variable, read **directly from
`process.env`, not through `defineModuleConfig`** (D13): a config item with an `env:` binding is
also overridable from the `app_configs` table, which would let a database row disable the guard
that is guarding it. Same for `AFFINE_DB_ADOPT` and `AFFINE_DB_COMPAT_SKIP`. When it is unset at
adopt time we mint a UUID, store it, and log:

```
deployment identity minted as <uuid>; set AFFINE_DEPLOYMENT_ID=<uuid> to enable wrong-database detection
```

Identity checking stays skipped-with-a-warning until it is set. Zero day-one breakage, and it
ratchets: once an operator pins the value in `extraEnv`, `IDENTITY_MISMATCH` is live.

**Stamp storage.** `app_configs`, id **`$deployment`**. `app_configs` is _not_ a free-form
store — `loadDbOverrides()` reads every row and merges it into the runtime config tree, with a
single hardcoded denylist entry as the only escape. But `override()` **ignores unknown config
modules outright**, so an id whose first dotted segment can never match a registered module
name is silently inert: it reaches neither the config tree nor the admin resolver, and needs no
patch to the denylist. The `$` prefix guarantees that. See G3 and D6.

Payload:

```jsonc
{
  "deploymentId": "<uuid|operator-supplied>",
  "adoptedAt": "<iso8601>",
  "adoptionMode": "fresh-install | implicit | explicit",
  "adoptedBy": { "version": "...", "buildSha": "..." },
  "lastMigratedBy": { "version": "...", "buildSha": "...", "at": "<iso8601>" },
}
```

## Wiring

- **`cli.ts`** gains a `db` command group — three commands, and the split between them is
  load-bearing (D17):

  - `db status` — the dry-run report: verdict, applied/known counts, pending list with tier and
    the matched DDL lines, identity state, and an explicit rollback-possible verdict. `--json`
    for CI. Always exits 0; it is informational.
  - `db check` — the gate. **Writes nothing.** Exits non-zero with a precise reason. Honors
    `--adopt`.
  - `db stamp` — records the adoption decision. Idempotent. Run **after** migrations. On an
    already-stamped database it updates only `lastMigratedBy`; if the verdict refuses, it declines
    to stamp.

  All three run on a **minimal Nest context — `ConfigModule` + `PrismaModule` only** — via a new
  `withMinimalApp` helper beside the existing `withCliApp`, so the gate cannot fail for Redis
  or Manticore reasons (D7). Verified viable: `PrismaFactory` depends only on `Config`.

- **`scripts/self-host-predeploy.js`**: the gate goes **before** any migration and the record goes
  **after**, both via the `execSync` idiom the script already uses:

  ```
  prepare → fixFailedMigrations → db check → prisma migrate deploy → data migrations → db stamp
  ```

  A non-zero exit from `db check` wedges the initContainer with nothing yet mutated, which is the
  safe failure. **Why the record cannot share the gate's position:** on a fresh install `app_configs`
  does not exist until `prisma migrate deploy` has run, and `writeStamp` throws Prisma `P2021`
  against it — measured, see D17. The gate must run before migrations to be worth anything (refusing
  _after_ applying a contracting migration is useless), so the two cannot occupy the same slot.

- **`app.module.ts`**: **two modules** (D14). `DbCompatModule` provides and exports
  `DbCompatService` only and is safe anywhere, including the minimal CLI context.
  `DbCompatGuardModule` adds the `OnApplicationBootstrap` guard, and **only `AppModule` imports
  it — never `FunctionalityModules`**. The CLI imports `FunctionalityModules`, so a guard reachable
  from there would make `db check` unable to run in precisely the situation it exists for (D10).

  The guard is also **inert under `env.testing`**: seven existing test files import `AppModule`
  and call `module.init()`, which runs bootstrap hooks. Without the test guard they would each
  acquire a new database query and a new failure mode.

Verified in the installed `@nestjs/core`: `listen()` calls `init()`, which runs
`callBootstrapHook()` before `httpAdapter.listen()`. A throw in `onApplicationBootstrap`
propagates out of `init()`, so the port is never bound — refusal is a real refusal, not a
window during which the server serves traffic.

## Emergency bypass — `AFFINE_DB_COMPAT_SKIP=1` (D11)

A guard that refuses to boot is by construction a way to take the fleet down, so a guard bug (a
mis-resolved migrations directory, a stamp written with the wrong id) must not be unrecoverable.
One bypass exists, and its three constraints are what keep it from being a hole:

- **Boot guard only, never the predeploy gate.** The gate is where mutation happens, and wedging
  it is already the safe failure.
- **Logs at ERROR on every boot**, naming the verdict it suppressed. A bypass left on is visible
  in logs rather than silent.
- **An incident tool, not a configuration option.** Not rendered by the chart; an operator sets
  it deliberately via `extraEnv`.

The objection is real — an escape hatch is the thing that gets left on — and the per-boot ERROR
is the answer to it.

## Testing

Regression fixtures are **drawn from the measured corpus, not invented**:

- `classify.spec.ts` — the pattern table, plus two corpus anchors:
  `20260714000001_drop_legacy_permission_and_subscription` must be `BLOCKING`, and
  `20260803095500_converge_copilot_runtime` must be `DESTRUCTIVE` and **not** `BLOCKING`. The
  second is the false-alarm regression the tiering exists to prevent.
- `compat.spec.ts` — the full verdict table over synthetic known/applied sets, including the
  rolled-back and unfinished-row edge cases.
- `db-compat.spec.ts` — ava against real Postgres, matching the existing server suite:
  `VIRGIN`/`EQUAL`/`DB_AHEAD`, stamp write-then-read, implicit vs explicit adoption, and
  `IDENTITY_MISMATCH`.

## Fork bookkeeping

Three **ADDITIVE** rows in `scripts/woven-patch-manifest.md` (the guard fails on an
unmanifested upstream-owned change, so this is not optional):

| File                                                     | Why the row                           |
| -------------------------------------------------------- | ------------------------------------- |
| `packages/backend/server/src/cli.ts`                     | `db` command group + `withMinimalApp` |
| `packages/backend/server/src/app.module.ts`              | one import: `DbCompatModule`          |
| `packages/backend/server/scripts/self-host-predeploy.js` | `runCompatGate()` call                |

Run `scripts/woven-manifest-guard.sh` until clean before pushing.

**Merge-checklist rewire.** `woven-patch-manifest.md` step 2 currently says "audit incoming
migrations for destructive DDL" by hand, and notes that this is "a prompt to a human, not the
guard". It becomes `yarn cli db status` — this plan converts that prompt into the tool.

## Phases (bead subtasks `affine-tc6.1`–`.6`)

- **T1 — Classifier + migration set (pure core).** `classify.ts`, `migration-set.ts`, and
  `classify.spec.ts` including both corpus anchors. No DB, no Nest. Deliverable: the tiering is
  demonstrably right on all 117 real migrations before anything depends on it.
- **T2 — DB state + verdict engine.** `db-state.ts` (raw `_prisma_migrations`, missing-table and
  failed-row handling), `compat.ts`, `compat.spec.ts`. Deliverable: every row of the verdict
  table is reachable and tested.
- **T3 — Identity stamp + adoption gate.** `identity.ts`, `AFFINE_DEPLOYMENT_ID` config item,
  `service.ts`, adoption decision logic, `db-compat.spec.ts` against real Postgres — asserting
  verdicts against a **populated** database carrying a real `_prisma_migrations` history, not
  only synthetic sets (D12).
- **T4 — CLI.** `withMinimalApp`, `db status`, `db check --adopt`, `--json`. First manifest row.
  Plus the **local rehearsal path**: load a dump into scratch Postgres and run
  `db status` / `db check` — the capability the deleted `woven-migration-rehearsal.sh`
  approximated, and the bead's item 2 (D12). Deliverable: the bead's third acceptance clause
  (operator can list pending migrations and see which are contracting) is met and demonstrable.
- **T5 — Enforcement.** `guard.ts`, `app.module.ts` import, `self-host-predeploy.js` gate, and
  the `AFFINE_DB_COMPAT_SKIP=1` boot-only bypass (D11). Remaining two manifest rows.
  Deliverable: acceptance clauses one and two.
- **T6 — Docs, rewire, cluster verification.** Rewrite `woven-patch-manifest.md` step 2; document
  `AFFINE_DEPLOYMENT_ID`, `AFFINE_DB_ADOPT` and `AFFINE_DB_COMPAT_SKIP`; **verify against a
  database recovered per the infra restore-drill runbook**
  (`infrastructure/docs/src/operations/affine-pg-restore-drill.md`), which is the bead's stated
  verification condition. Per D12 this is now only the **CNPG cluster drill** — the local
  populated-database verification has moved to T3/T4 — so it is the one phase needing an
  environment outside this repo, and the one needing an infra-repo owner (OQ-2).

## Not covered, stated plainly

An image built **before** this lands cannot refuse anything. The already-spent rollback across
`20260714000001_drop_legacy_permission_and_subscription` — a CONTRACT migration present at
`woven/main` HEAD and inside the pinned image — stays unprotected, and a
**verified-restorable** backup remains the only net for it. This plan stops the _next_ one.

Data migrations (`_data_migrations`) are not classified in T1–T5; unlike prisma migrations they
carry a `down()`. See OQ-4.
