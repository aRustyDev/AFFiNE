# Decision log — adopt-existing-database

Operator decisions taken 2026-08-31 during design of `affine-tc6`. D1–D4 were explicit operator
calls; D5–D10 follow from them plus the grounding measurements.

- **D1 — Full scope: all four items from the bead, identity included.** Compatibility check,
  explicit ADOPT mode, dry-run report, **and** the deployment-identity marker the bead lists as
  "ideally". Rationale: identity is cheap given the `app_configs` precedent (G3), and without it
  `UNRELATED` collapses into a heuristic guess — pointing a server at the wrong populated
  database would stay silently adoptable. Closes the bead outright rather than leaving a
  follow-up. _Status: accepted._

- **D2 — Enforce at both the predeploy gate and a read-only boot check.** Predeploy is the
  mutating gate: it classifies, refuses before `prisma migrate deploy` runs, and is where ADOPT
  stamps identity. The boot check re-verifies read-only and refuses to listen. Rationale: G1
  shows the initContainer already runs on every pod start, so predeploy alone covers the k8s
  path well — but the compose path, a directly-run image, and a disabled initContainer are not
  covered, and the boot check costs one query. _Status: accepted._

  Note the corrected premise: this decision was first argued on the assumption of a Helm hook
  Job, which would **not** re-run on pod restart. G1 disproved that. The conclusion held for
  different reasons than originally offered.

- **D3 — Adoption: auto-adopt when provably safe, require the flag when not.** Stamp and log an
  implicit adoption when the state is `EQUAL` or every pending migration is
  `EXPAND`/`DESTRUCTIVE`; refuse without `--adopt` / `AFFINE_DB_ADOPT=1` when any pending
  migration is `BLOCKING`. Rationale: the strict alternative (always require the flag) is the
  truest reading of "adoption is a decision, not an accident of user count" — but shipping it
  would wedge the running cluster's next pod start until `extraEnv` gained the flag, coupling
  an infra change to this release. The live cluster is `EQUAL`, so this variant rolls out
  invisibly while putting the explicit gate exactly where the irreversibility is.
  _Status: accepted._

- **D4 — Tiered DDL classification: `BLOCKING` / `DESTRUCTIVE` / `EXPAND`.** Only `BLOCKING`
  gates. Rationale: measured in G2a — of 117 migrations the final rule set tiers **17 BLOCKING,
  14 DESTRUCTIVE, 86 EXPAND**, and **8 of the 14 DESTRUCTIVE carry `drop-constraint` with no
  blocking rule**. A single flag would report "rollback impossible" for those eight, and an alarm
  that cries wolf is the one operators learn to pass with the override. The reviewed-exception-file
  variant was rejected as premature: the measurement found no false positives needing one.
  _Status: accepted._

  The supporting figures were wrong twice before they were right, which is itself worth recording.
  The "only DROP CONSTRAINT" count went "two" (partial spot-check of a grep) → "nine" (hand count)
  → **eight** (mechanical count). And the tier totals went 18/14/85 → **17/14/86** once T1's review
  removed a false-positive `BLOCKING`. The decision never changed; only the evidence for it got
  more accurate. Do not re-derive these by eye — run the classifier.

- **D4a — Statement-level, dollar-quote-aware, identifier-aware scanning (not per-line).** Follows
  from G2b/G2c/G2d. Three properties, all load-bearing rather than defensive:
  1. Scrubbing `$$`-quoted bodies — without it, migrations gain spurious `DESTRUCTIVE` verdicts
     from DDL inside function bodies the migration never executes.
  2. Scrubbing **double-quoted identifiers** — without it, `retype-column` matched a column
     literally named `"type"` (the false `BLOCKING` that made the corpus count 18 instead of 17),
     and an apostrophe inside an identifier such as `"user's"` blanked the rest of the file,
     failing OPEN to `EXPAND`. Safe for detection because every rule matches keywords, not
     identifiers.
  3. Statement-level matching after whitespace collapse — guards a latent per-line bug, where a
     multi-line `ALTER COLUMN "x"` / `SET NOT NULL` would be missed. Not in the corpus today, but
     prisma's formatting could emit one at any time.

  All three carry explicit T1 tests. Property 2 was added during T1 code review, not design.
  _Status: accepted._

- **D4b — Unparseable input fails CLOSED.** `DdlClassification` carries `unterminated: boolean`;
  when a block comment, dollar body, string literal or quoted identifier runs to EOF, the tier is
  forced `BLOCKING` with a synthetic `unparseable` hit. For a gate, "I lost my place" must never
  render as "additive" — and a migration with an unterminated literal would fail in prisma anyway,
  so assuming the worst costs nothing real. An unterminated `--` line comment is deliberately
  exempt: reaching EOF without a trailing newline is valid SQL, so flagging it would fire the
  fail-closed path on well-formed input. Zero corpus migrations trip this path.

  Same rule for missing files: `MigrationSet.sql()` returns `string | null`, and `compat.ts` maps
  a null to `BLOCKING` with an `unreadable-migration` hit. Returning `''` would have reported an
  unreadable migration as additive. _Status: accepted (T1 review)._

- **D5 — Deployment identity is asserted from outside the database, via `AFFINE_DEPLOYMENT_ID`.**
  An id read _out_ of a database cannot tell you it is the wrong database — the check would be
  circular. So identity must come from config. Reachable on the infra side through the chart's
  existing `.Values.extraEnv` with no template change (G1). _Status: accepted._

- **D6 — Stamp stored in `app_configs` at id `$deployment`.** Not a new table, and not a
  `schema.prisma` model. Rationale: G3 — `app_configs` merges every row into the runtime config
  tree, but `override()` ignores unknown config modules, so a `$`-prefixed id is inert without
  patching the hardcoded denylist. Avoids both a `schema.prisma` manifest row and a fork-owned
  prisma migration (which would show as drift under `prisma migrate dev`). _Status: accepted._

- **D7 — The CLI gate runs on a minimal Nest context (`ConfigModule` + `PrismaModule`), not
  `CliAppModule`.** Rationale: G8 — `CliAppModule` pulls all of `FunctionalityModules` plus
  `IndexerModule`, so a gate standing on it could fail for Redis or Manticore reasons and mask
  or fake a database verdict. A new `withMinimalApp` helper beside `withCliApp`.
  _Status: accepted._

- **D8 — No separate `db adopt` subcommand (YAGNI).** The bead says "flag or subcommand";
  `db check --adopt` plus `AFFINE_DB_ADOPT=1` satisfies it, and env is the knob the
  initContainer can actually reach without an infra template change. A third subcommand would
  be a second code path to the same state transition. _Status: accepted._

- **D9 — `UNREADABLE` is asymmetric: predeploy refuses, boot logs and continues.** Rationale:
  "fail closed" is right where the failure is safe. A predeploy wedge leaves the old fleet
  serving; refusing to boot over a _packaging_ fault would take the fleet down for a non-safety
  reason. And because the initContainer shares the pod and image, predeploy has already refused
  before the boot path can see it in the deployment that matters. Not-verifiable is recorded as
  an ERROR, never as verified-good. _Status: accepted._

- **D10 — The boot guard goes in `AppModule` only, never `FunctionalityModules`.** The CLI
  imports `FunctionalityModules` (G8), so a guard placed there would make `db check` refuse to
  start in exactly the situation the operator needs it — a chicken-and-egg that would leave no
  way to diagnose or adopt. _Status: accepted._

- **D11 — One emergency bypass, `AFFINE_DB_COMPAT_SKIP=1`, boot-only and loudly logged.**
  Resolves OQ-1. A guard that refuses to boot is by construction a way to take the fleet down,
  so if the guard itself is wrong (a mis-resolved migrations directory, a stamp written with the
  wrong id) there must be a way in. Constraints that make it acceptable rather than a hole:
  it skips the **boot guard only and never the predeploy gate** (the gate is where mutation
  happens and wedging it is already safe); it logs at **ERROR on every boot**, naming the
  verdict it suppressed, so a bypass left on is visible rather than silent; and it is documented
  as an incident tool, not a configuration option — not rendered by the chart, set deliberately
  via `extraEnv`. The argument against is real (an escape hatch is the thing that gets left on);
  the per-boot ERROR is what answers it. _Status: accepted 2026-09-01 (operator)._

- **D13 — The three knobs are read from `process.env` directly, NOT via `defineModuleConfig`.**
  `AFFINE_DEPLOYMENT_ID`, `AFFINE_DB_ADOPT`, `AFFINE_DB_COMPAT_SKIP`. A `defineModuleConfig` item
  with an `env:` binding is also **overridable from the `app_configs` table**, which for a safety
  control is backwards: an admin (or a stray row) could set `skip` in the database and disable the
  guard, and the guard would be reading its own kill switch from the thing it is guarding. Direct
  env reads also keep the boot guard independent of config load order. Consequence: these knobs do
  not appear in the admin UI and cannot be changed at runtime — correct for an incident tool.
  Supersedes the design's earlier description of `AFFINE_DEPLOYMENT_ID` as "a fork-owned config
  item". _Status: accepted._

- **D14 — Two modules, so the CLI never self-gates.** `DbCompatModule` provides and exports
  `DbCompatService` only, and is safe to import anywhere including the minimal CLI context.
  `DbCompatGuardModule` imports it and adds the `OnApplicationBootstrap` guard; **only `AppModule`
  imports that one.** Implements D10 concretely: a single module carrying both would make
  `db check` run the guard in its own bootstrap, which is the chicken-and-egg D10 forbids.
  _Status: accepted._

- **D12 — T6's restore-drill verification splits; the local half comes forward.** The
  populated-database verification moves into T3/T4, where a real Postgres is already required:
  the ava suite asserts verdicts against a database carrying a real `_prisma_migrations` history,
  not only synthetic sets, plus a local rehearsal path (load a dump into scratch Postgres, run
  `db status` / `db check`) — which is the capability the deleted `woven-migration-rehearsal.sh`
  approximated and the bead's item 2 calls homeless. Only the **CNPG cluster drill** stays in T6.
  Rationale: the runbook's measured timings make the drill a real cost, so it should be spent
  once on shipped behaviour; and OQ-2 (does the runbook gain a "bring a server up against the
  restored database" step?) cannot be answered well until the command exists and its exact
  invocation and output are known. _Status: accepted 2026-09-01 (operator)._

- **D15 — A ninth verdict, `SCHEMA_INCOMPLETE`, and `populated: boolean | null`.** Added during T2
  code review, which verified a fail-open: a database whose `_prisma_migrations` records applied
  migrations but whose `users` table is absent reported `EQUAL` with `rollbackPossible: true` — a
  clean bill of health for a broken schema — and with both tables absent reported `VIRGIN`, i.e.
  "fresh install, proceed", after which `migrate deploy` collides on `CREATE TABLE`.

  Root cause: `populated` was a plain boolean, so a _failed_ user count (undefined table, swallowed)
  was indistinguishable from a genuine zero. Under a fail-closed principle an unknown must never
  render as `false`. `populated` is now `boolean | null`; `SCHEMA_INCOMPLETE` fires on
  `populated === null && hasMigrationsTable` and refuses at both enforcement points, while `VIRGIN`
  accepts a null only when `hasMigrationsTable` is also false — a schema with neither table is
  genuinely empty, not contradictory.

  Worth stating why this is in scope rather than gold-plating: a partially-restored database is
  **item 3 of the bead**, so it is the scenario the work exists for. _Status: accepted (T2 review)._

- **D16 — `rollbackPossible` is `null` for `EQUAL` and computed for `VIRGIN`.** The engine
  classifies only _pending_ migrations and never what is already applied. `EQUAL` therefore used to
  hard-code `true`, asserting rollback safety on evidence it had not gathered — in the state the
  live cluster is normally in, and rendered to operators as `POSSIBLE`. Meanwhile `VIRGIN` computed
  the real answer (everything pending, some `BLOCKING`) and discarded it as `null` → `UNKNOWN`.
  Exactly backwards. Now `EQUAL` reports `null` (the question genuinely does not apply when nothing
  is pending) and `VIRGIN` reports the computed value, because on a fresh install everything will be
  applied and "IMPOSSIBLE" is both factual and actionable. _Status: accepted (T2 review)._

- **D17 — `db check` is pure; a separate `db stamp` records, AFTER migrations.** Forced by a
  showstopper found in T3 review and verified directly: the predeploy gate runs **before**
  `prisma migrate deploy`, so on any fresh install `app_configs` does not exist yet, and both
  `readStamp` and `writeStamp` throw Prisma `P2021`:

  ```
  readDbState degraded OK: {"hasMigrationsTable":false,"rows":[],"populated":null}
  readStamp  THREW → code: P2021
  writeStamp THREW → code: P2021
  ```

  `report()` therefore threw before `decide()` was reached — **fresh installs could not deploy at
  all**, and `db status` (specified to always exit 0) crashed on a virgin database. `db-state.ts`
  guarded both its reads with `isUndefinedTable`; `identity.ts` guarded neither.

  Error handling alone cannot fix it: `writeStamp` needs `app_configs` too, so a fresh install's
  stamp **cannot be written at the pre-migration gate** at any level of defensiveness. Hence the
  split. New predeploy order:

  ```
  fixFailedMigrations → db check (gate; writes nothing) → prisma migrate deploy
                      → data migrations → db stamp (records; app_configs now exists)
  ```

  Two things fall out of the split beyond fixing the crash, and both are improvements on their own
  merits: a command called `check` no longer mutates the database, and `db stamp` gives
  `lastMigratedBy` a natural update point (it previously named the _adopting_ binary forever,
  because `recordAdoption` was its only writer and only ran on first adoption).

  This does not reverse D8. D8 rejected a `db adopt` subcommand duplicating the operator's adopt
  _decision_; `db stamp` is a deploy-pipeline step, and `--adopt` / `AFFINE_DB_ADOPT` remain the
  only way to express that decision. _Status: accepted (T3 review)._

- **D18 — an unreadable deployment stamp REFUSES rather than reading as absent.** T3 review found a
  fail-open: `readStamp` collapsed "no row" and "row present but unparseable" into `null`, so
  `identity.kind` became `absent`, the adoption gate ran, and `recordAdoption` **upserted over the
  corrupt row**. Concretely: a database belonging to `prod-a` with a corrupt stamp, and a `prod-b`
  server pointed at it, should be `IDENTITY_MISMATCH`; instead it adopted and destroyed the
  evidence. That contradicts the module's own philosophy, where an unreadable _migration_ is
  explicitly coerced to `BLOCKING` to fail closed.

  `IdentityState` gains a `corrupt` arm and `buildReport` maps it to `IDENTITY_MISMATCH` with a
  distinct reason. It refuses **even when `AFFINE_DEPLOYMENT_ID` is unset**: we cannot confirm whose
  database this is, and the row is evidence of a prior adoption we must not clobber.

  Also in the same area: `parseStamp` validated only `deploymentId` and `adoptedAt` (and the latter
  only for `typeof === 'string'`, so `''` passed) before asserting the full type. A row missing
  `adoptionMode`/`adoptedBy` crashed a renderer reading `adoptedBy.version` — again in the command
  specified to always exit 0. All fields are now validated. _Status: accepted (T3 review)._

- **D19 — `populated === false` selects `fresh-install`, not adoption.** `decide()` never read
  `populated`, so `hasMigrationsTable: true` with zero users — precisely the state a fresh install
  is in after D17's `db check → migrate → db stamp` sequence — logged "ADOPTING pre-existing
  database" about a database with no data, and with a `BLOCKING` pending migration would refuse
  "adoption of a pre-existing database" holding zero rows. _Status: accepted (T3 review), then
  **amended by D21** — as first written it caused a fail-open._

- **D21 — `populated` means "any content", and the BLOCKING gate runs BEFORE the fresh-install
  return.** D19 was drafted as "select `fresh-install` and suppress the gate". The word _suppress_
  was a mistake: I wanted a relabel and specified a bypass, and it was implemented faithfully.

  Two independent errors compounded. First, `populated` was `user.count() > 0`, and **AFFiNE
  deliberately preserves content when users are deleted** — `Workspace` has no foreign key to
  `User`, `Snapshot.createdByUser` is `onDelete: SetNull` with a schema comment saying snapshots
  outlive users, and `Blob` cascades from `Workspace`. So zero users does not mean zero data (G7a).
  Second, the fresh-install return sat in front of the BLOCKING check, so the gate was skipped
  rather than merely relabelled.

  Measured result before the fix: 2 workspaces, 0 users, unstamped, one real contracting migration
  pending → `check()` returned `ok: true, adopt: 'fresh-install'`, silently, at LOG level, and
  durably recorded `fresh-install`. Routine trigger: clone production to staging and truncate
  `users` to scrub PII.

  Both halves fixed: `populated` is now users **OR** workspaces (null if either read hits an
  undefined table), and the gate runs first, so correctness no longer depends on `populated` being
  right. `VIRGIN` still bypasses — a virgin database has all 117 migrations pending, 17 of them
  BLOCKING, and gating a fresh install would be absurd; a genuinely fresh post-migrate install has
  nothing pending, so the gate is a no-op there anyway.

  The lesson, since this is the second time: **an instruction that says "suppress the gate" will get
  the gate suppressed.** Say what to relabel, not what to skip. _Status: accepted (T3 re-review)._

- **D22 — the initial deployment stamp is first-writer-wins.** `stamp()` was read-modify-write with
  no coordination. Two pods running `db stamp` on an unstamped database both see `identity: absent`,
  and with `AFFINE_DEPLOYMENT_ID` unset — the day-one default D5 explicitly supports — each mints
  its own UUID; last writer wins. The loser has already logged
  `set AFFINE_DEPLOYMENT_ID=<UUID-A>` while the database holds UUID-B, so an operator following the
  ratchet's own instruction gets `IDENTITY_MISMATCH` and a server that refuses to boot. Reachable
  with `replicas: 2` on a fresh install, since `db stamp` runs per-pod in the initContainer.

  Initial adoption now uses `create()` and, on a unique violation, re-reads and falls through to the
  `lastMigratedBy` update — and **logs the persisted id, not the minted one**, which is the half
  that actually prevents the bricking. In-repo precedent for the alternative: `AppConfigModel.save()`
  takes `pg_advisory_xact_lock` before touching `app_configs`, so this codebase already treats
  concurrent writes there as needing coordination. _Status: accepted (T3 re-review)._

- **D20 — `CompatDecision` carries `bootMayContinue`.** The `REFUSING_VERDICTS` branch and the
  `UNREADABLE` branch returned byte-identical decisions, so the boot guard had to reach into
  `decision.report.verdict` to recover D9's asymmetry — and the obvious `if (!decision.ok) throw`
  would cause fleet-wide boot failure on a packaging fault, which is the exact outcome D9 exists to
  prevent. The asymmetry is now a named field, set where it is understood and testable there.
  _Status: accepted (T3 review)._

- **D23 — the boot check runs in `server.ts`, not in an `OnApplicationBootstrap` hook.** The
  original design put the guard in a lifecycle hook, and I verified twice — in the installed Nest
  source — that bootstrap hooks complete before the port binds. That was true and **insufficient**:
  I checked what ran before _listening_, never what ran before the _guard_.

  T5 review measured the real hook order on a live `AppModule` boot:

  ```
  BOOTSTRAP_ORDER = ["BackendRuntimeProvider", "StorageRuntimeProvider", "DbCompatGuard"]
  ```

  Both of those call native `runMigrations()` from their own `onApplicationBootstrap`. Nest sorts
  hooks by descending module distance with a stable tie-break, and the guard module was added after
  `FunctionalityModules`, so it could never win. An older binary meeting a `DB_AHEAD` database would
  have two migration runners touch it before the guard refused — in exactly the scenario this bead
  exists for.

  A second, independent defect pushed the same way: `server.ts` passes `bufferLogs: true`, and
  `NestFactory.create` (unlike `createApplicationContext`) never calls `flushLogsOnOverride()`, so
  `app.useLogger()` leaves the buffer attached and `Logger.flush()` is reached only inside
  `listen()`'s callback. A guard throwing in a bootstrap hook therefore had its entire report
  **dropped** — reproduced: the only output was a raw Node stack. The bead's criterion is "fails
  fast with a clear message".

  Both are fixed by hoisting: `NestFactory.create()` runs no lifecycle hooks at all, so a call
  between it and `listen()` strictly precedes every module hook, and the thrown error now carries
  the rendered report so it survives any logger state. Three simplifications fall out —
  `DbCompatGuardModule` is deleted, the `env.testing` short-circuit is unnecessary (tests import
  `AppModule`, never `server.ts`), and D10 is satisfied structurally rather than by convention,
  since `src/index.ts` dispatches to `runCli()` or `runServer()`.

  `app.module.ts` still adds `DbCompatModule` — the service-only module, no hook — because
  `app.get(DbCompatService)` must resolve. Discovered by booting the real server after a full
  revert: `UnknownElementException: Nest could not find DbCompatService element`. My instruction to
  revert `app.module.ts` entirely was wrong. _Status: accepted (T5 review)._

  Proven end-to-end afterwards, not just reasoned: booting the real server against a forced
  `DB_AHEAD` database refused before "Nest application successfully started", wrote **zero rows**
  to `workspaces`/`users` (so the native runners never ran), and the thrown error's stack carried
  the full report.

- **D24 — the `predeploy` npm script carries the gate too.** Grounding G1 established that the
  _infrastructure_ repo's chart invokes `scripts/self-host-predeploy.js`. True — and I never checked
  this repo's own chart, which runs `yarn predeploy`, a different script:
  `yarn prisma migrate deploy && yarn cli run`. So upstream's Helm chart, `render.yaml`, and any
  bare `yarn predeploy` migrated **ungated and unstamped**.

  Fixed in the script itself rather than by repointing it at `self-host-predeploy.js`, which would
  also pull in private-key generation the cloud chart should not get:

  ```
  "predeploy": "yarn cli db check && yarn prisma migrate deploy && yarn cli run && yarn cli db stamp"
  ```

  The lesson generalises: "the deployment calls X" is a claim about **one** deployment. Enumerate
  the callers. _Status: accepted (T5 review)._

- **D25 — the corpus tests assert INVARIANTS, not the measured distribution.** The first version
  asserted `{ BLOCKING: 17, DESTRUCTIVE: 14, EXPAND: 86 }` of exactly 117, plus a separate
  `names.length === 117`. Operator review caught the flaw: upstream adds migrations on every merge,
  so both tests would break on each one — and break **uninformatively**. "Expected 117, got 118"
  says nothing about whether the classifier is still correct, and the only sensible remedy is to
  edit the number. An assertion that must be edited routinely trains people to edit it without
  thinking, which is worse than no assertion — and it made the "do not soften this" comment beside
  it into noise.

  Root cause: two different jobs were conflated. The tests should protect the **rule set**; the
  merge-checklist `db status` step covers **new content**. Only the first belongs in a fixture.

  Replaced with three invariants:
  1. **Total accounting** — `BLOCKING + DESTRUCTIVE + EXPAND === names.length`, catching a
     classifier that throws or returns an unexpected tier.
  2. **Monotonic floors** — `BLOCKING >= 17`, `DESTRUCTIVE >= 14`. Sound because prisma migration
     directories are **append-only**: applied migrations are immutable history, so a tier's
     population can only grow. No floor on `EXPAND`, which grows with every additive migration and
     so asserts nothing about the rules.
  3. **Per-rule "still fires"** — for the 7 rules with real corpus coverage (`drop-constraint`,
     `drop-index`, `drop-table`, `drop-column`, `retype-column`, `set-not-null`, `delete-from`).
     Stronger than any aggregate and it does not decay as the corpus grows: a floor could stay
     satisfied while one specific rule silently died. `rename-table`, `rename-column` and
     `truncate` match nothing in this repo's history and stay unit-test-only.

  Over-detection is covered by the four named anchors, which are unchanged — if a rule turned
  greedy, `converge_copilot_runtime` stops being DESTRUCTIVE-not-BLOCKING, or the function-body-only
  migrations stop being EXPAND.

  The asymmetry is the point: **bumping a floor up is a safe, optional tightening; editing an exact
  count is mandatory and thoughtless.**

  Both halves were verified rather than argued. Neutering `drop-table`'s pattern failed the floor
  test ("BLOCKING fell to 13, below the measured floor of 17") and the per-rule test ("rule
  drop-table no longer matches any migration in the corpus"), so the invariants have teeth. Adding
  two simulated upstream migrations — one additive, one contracting — left all 43 tests passing with
  no edits, where the old design would have failed two.

  `migration-set.spec`'s `117` was incidental: that test exists to prove `resolveMigrationsDir()`
  finds the real directory. It now asserts shape — non-empty, `migration_lock.toml` present, names
  sorted and matching `/^\d{14}[_-]\S+$/`, every `migration.sql` readable. Measuring first was
  worth it: `20250303105325-notification` separates with a **hyphen**, so an assumed `_` would have
  been wrong.

  A checked-in golden file of name → tier was considered as the stronger alternative. Rejected: its
  real benefit is per-migration pinning, which the anchors already provide for the cases that
  matter, at the cost of ~117 lines of committed data plus a regeneration step at every merge.
  _Status: accepted (operator, 2026-09-03)._

## Rejected approaches

- **All logic in `self-host-predeploy.js` as plain JS.** No app-graph coupling and it would run
  even with a broken bundle, but the boot guard could reuse none of it, so the classifier gets
  written twice, and `scripts/*.js` is not reachable from the ava suite. Duplicated safety logic
  is worse than a slightly larger diff.
- **Build-time codegen of the expected migration list into the bundle.** Robust against
  filesystem layout, but adds a generated artifact to a repo whose merge checklist already
  documents pain with one (`schema.gql`, step 4). Unnecessary: G5 shows `/app/migrations` ships.
- **A dedicated identity table.** Either via `schema.prisma` (an upstream-owned manifest row, and
  a fork-owned prisma migration interleaving with upstream timestamps) or via raw SQL with no
  model (which reports as drift to any developer running `prisma migrate dev`). D6 avoids both.
- **Deriving identity from something already in the database** (e.g. the `auth.session.signingKeys`
  ring). Fails for the same reason as D5: it is not externally asserted, so it cannot detect a
  wrong database.
