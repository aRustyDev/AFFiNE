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
  gates. Rationale: measured in G2 — two of the 25 destructive migrations hit only on
  `DROP CONSTRAINT`, which an older binary survives. A single flag would report "rollback
  impossible" for those, and an alarm that cries wolf is the one operators learn to pass with
  the override. The reviewed-exception-file variant was rejected as premature: the measurement
  found no false positives needing one. _Status: accepted._

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
