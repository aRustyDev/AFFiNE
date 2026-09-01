# Grounding — adopt-existing-database (verified 2026-08-31)

Authored against branch `claude/affine-tc6-bead-design-04abf1`, forked from `woven/main` at
`c6fc3b2dec`. Every claim below was measured or read on this tree, not recalled. Pointers are
discovery descriptions plus enough anchor text to re-find them after a rebase.

## G1 — Deployment topology: an initContainer, not a Helm hook

`infrastructure/products/affine/kube/charts/affine/templates/deployment.yaml` runs prisma
migrations as an **initContainer in the server pod**:

```yaml
- name: migration
  command: ['sh', '-c', 'node ./scripts/self-host-predeploy.js']
```

The template carries its own rationale: an initContainer "instead of a helm hook Job: a
pre-install hook deadlocks umbrella installs (it needs postgres, which is a regular resource of
the same release), while an initContainer is simply retried by the kubelet until the database is
reachable. The predeploy script is idempotent."

`.docker/selfhost/compose.yml` runs the **identical** command as a
`service_completed_successfully` dependency of the server.

Three consequences, all load-bearing for this plan:

- `self-host-predeploy.js` lives in **this** repo, so a gate inside it needs **no infra change**.
- Being an initContainer rather than a hook, it runs on **every pod start** — restarts and
  scale-ups included. An earlier framing of this design assumed a Helm hook and therefore
  assumed restarts were unguarded; that framing was wrong.
- An initContainer refusal wedges the new pod in `Init` and stalls the rolling update, so the
  **old fleet keeps serving**. Refusal is a safe failure, not an outage.

The chart's env block (`affine.env` in `_helpers.tpl`) does **not** set `AFFINE_ENV`, but does
render `.Values.extraEnv`. So `AFFINE_DEPLOYMENT_ID` is a **values-only** change on the infra
side — no template edit.

## G2 — Migration corpus: the destructive scan is accurate, but one tier is not enough

`packages/backend/server/migrations/` holds **117** migration directories. Running the prior-art
pattern set from `git show b6805c2e32^:scripts/woven-migration-rehearsal.sh`
(`DROP TABLE|DROP COLUMN|DROP CONSTRAINT|TRUNCATE +TABLE|RENAME (TO|COLUMN)|ALTER COLUMN .*SET NOT NULL`)
across all of them yields **25 migrations with hits**.

Spot-checking the hits found **no false positives** — they are genuine destructive DDL:

| Migration                                 | Sole/representative hit                                                  |
| ----------------------------------------- | ------------------------------------------------------------------------ |
| `20260712093000_mcp_credentials`          | `DROP TABLE IF EXISTS "access_tokens";`                                  |
| `20260212053401_workspace_analytics`      | `DROP COLUMN IF EXISTS "feature_id"`, `DROP TABLE IF EXISTS "features"`  |
| `20260803095500_converge_copilot_runtime` | `DROP CONSTRAINT "ai_sessions_metadata_prompt_name_fkey"` — **only hit** |

So text scanning is sound and needs no reviewed-exception file (yet). But the last row is why a
single contracting flag is wrong: dropping a foreign key is destructive and an older binary
**reads and writes past it without noticing**. Flagging it "rollback impossible" is a false
alarm.

`20260714000001_drop_legacy_permission_and_subscription` has **15** hits and is the genuine
`BLOCKING` anchor — and per the bead's 2026-08-31 re-frame it is already shipped inside the
pinned image, which is why the rollback half of this bead is spent rather than pending.

### G2a — Measured distribution under the FINAL tiered rule set

A prototype of `classify.ts` (dollar-quote-aware statement splitting, the ten rules in the design's
tier table) was run over all 117 migrations. **These are the numbers the T1 tests assert:**

```
total=117  BLOCKING=18  DESTRUCTIVE=14  EXPAND=85
```

Anchors confirmed: `20260714000001_drop_legacy_permission_and_subscription` → **BLOCKING**
(`delete-from,drop-table,drop-index,drop-column`); `20260803095500_converge_copilot_runtime` →
**DESTRUCTIVE**, sole rule `drop-constraint`; `20260712093000_mcp_credentials` → **BLOCKING**
(`drop-table`).

**Correction to an earlier estimate.** During design this was described as "two migrations whose
sole hit is `DROP CONSTRAINT`", from a partial spot-check of the naive grep. Measured properly:
**9 of the 14 `DESTRUCTIVE` migrations carry `drop-constraint` with no blocking rule**, so a
single-flag scan would falsely report "rollback impossible" for nine migrations, not two. The
remaining five are `drop-index`-only. This strengthens D4 rather than weakening it.

The tiered set finds 32 migrations with hits versus the naive set's 25 because it adds
`DROP INDEX` and `DELETE FROM` — both correctly `DESTRUCTIVE`, neither blocking.

### G2b — Dollar-quote scrubbing is load-bearing, not defensive

**12 migrations contain `$$`-quoted function bodies.** Running the same prototype with
dollar-quote handling removed changes three verdicts:

```
with    $$ scrubbing: BLOCKING=18  DESTRUCTIVE=14  EXPAND=85
without $$ scrubbing: BLOCKING=18  DESTRUCTIVE=17  EXPAND=82
```

The three false positives are `20250521083048_fix_workspace_embedding_chunk_primary_key`
(`drop-index,drop-constraint`), `20260512133700_workspace_runtime_states` (`delete-from`) and
`20260514000000_entitlement_quota_states` (`delete-from`) — all DDL inside a function body, none
of it executed by the migration itself. This confirms the deleted rehearsal script's warning that
"plain DELETE/TRUNCATE inside trigger/function bodies is NOT flagged", and it earns a dedicated
T1 test rather than being left implicit.

Naive `;`-splitting is therefore wrong: a `;` inside `$$ … $$` is not a statement terminator.

### G2c — Per-line scanning would be a latent bug

No migration in the corpus currently splits `ALTER COLUMN "x"` from its `SET NOT NULL` across
lines (checked: zero matches for a line ending in `ALTER COLUMN "…"`). So a per-line scan would
pass today — but it would silently miss

```sql
ALTER TABLE "foo" ALTER COLUMN "bar"
  SET NOT NULL;
```

which prisma's generated formatting could produce at any time. Statement-level scanning after
whitespace collapse is what makes the rule set robust, and it costs nothing extra.

## G3 — `app_configs` is NOT a free-form store, but a `$`-prefixed id is inert

This corrected a wrong assumption mid-design and is the single most important finding for the
identity stamp.

`ServerService.loadDbOverrides()` (`src/core/config/service.ts`) reads **every** row of
`app_configs` and merges each into the runtime config tree via `set(overrides, config.id, ...)`.
The only escape is a **hardcoded denylist of one entry**, `'auth.session.signingKeys'`. So a
naive stamp row would be merged into app config, and keeping it out would mean patching that
list — an upstream-owned file, in a spot where a future refactor would silently reintroduce the
leak.

But `override()` in `src/base/config/register.ts` opens with:

```js
const moduleDescriptors = APP_CONFIG_DESCRIPTORS[module];
// ignore unknown config module
if (!moduleDescriptors) {
  return;
}
```

**Unknown config modules are ignored outright.** An id whose first dotted segment can never
match a registered module name is therefore silently dropped: it reaches neither the config tree
nor the `appConfig()` admin resolver (which returns the _tree_, not the rows). No denylist patch
needed. A `$` prefix guarantees the segment can never collide, including with a future
fork-owned config module.

Precedent for using `app_configs` as an opaque store already exists: `core/auth/signing-key.ts`
stores a key ring at id `auth.session.signingKeys` via `models.appConfig.createIfAbsent` — which
is exactly why that one id needed the denylist entry.

**Checked for a stamp-eating hazard and cleared:** the infra repo's
`products/affine/kube/scripts/prune-app-configs.sh` deletes `app_configs` rows, but only ids
explicitly listed in `GIT_OWNED_KEYS`, with a comment stating the scope "is deliberately narrow
… and it must never become one" (a wipe). A `$deployment` row is not at risk.

## G4 — Nest boot ordering: a bootstrap throw means the port is never bound

Read in the installed `node_modules/@nestjs/core/nest-application.js`:

- `listen()` (line ~174) calls `await this.init()` before touching the adapter.
- `init()` (line ~95) runs `await this.callBootstrapHook()` at line 107; `httpAdapter.listen`
  happens at line ~190, after `init()` has resolved.

So a throw from `onApplicationBootstrap` propagates out of `init()` and the socket is never
bound. The boot guard is a real refusal, not a window in which the server serves traffic. This
was verified rather than assumed, because the whole value of the boot guard depends on it.

## G5 — The migrations directory ships in the image

`scripts/woven.Dockerfile` copies the whole `packages/backend/server` tree to `/app`, and
`scripts/docker-clean.mjs` prunes only server-native binaries and prisma query/schema engines —
it never touches `migrations/`. It cannot: `yarn prisma migrate deploy` needs the directory at
runtime, and the predeploy script runs it inside the image.

So `/app/migrations/*/migration.sql` is readable at runtime, and the binary's expected migration
set can be read from the filesystem. `process.cwd()` is `/app` in the image and
`packages/backend/server` in dev, so `resolve(process.cwd(), 'migrations')` covers both, with a
fallback relative to the bundle for direct `node dist/main.js` invocations from elsewhere.

The deleted rehearsal script confirms the same layout from the outside — it read
`/app/migrations/*/` out of the image by `docker run`.

## G6 — Migration bookkeeping tables

- **`_prisma_migrations`** — Prisma's own, no model in `schema.prisma`, so it needs `$queryRaw`.
  Relevant columns per the prior-art script: `migration_name`, `checksum`, `finished_at`,
  `rolled_back_at`, `applied_steps_count`. Absent on a virgin database (`42P01`).
- **`_data_migrations`** — mapped by the `DataMigration` model in `schema.prisma`
  (`id`, `name` unique, `started_at`, `finished_at`). Driven by `src/data/commands/run.ts`, whose
  migrations carry both `up()` and `down()`, and an optional `always` flag.

The prior-art script recorded a distinction worth carrying: "recorded" should mean any row
including deliberately rolled-back ones, so managed rollbacks are not misread. This plan adopts
the sharper form — `applied` = `rolled_back_at IS NULL`, with unfinished rows getting their own
verdict.

## G7 — The implicit-adoption path this bead is about

`ServerService.initialized()` (`src/core/config/service.ts`):

```ts
async initialized() {
  if (!this._initialized) {
    const userCount = await this.models.user.count();
    this._initialized = userCount > 0;
  }
  return this._initialized;
}
```

A restored database with users therefore skips the setup wizard and the instance adopts it with
no compatibility check whatsoever. Note also that the result is cached in-process once true, and
that the cache is only populated on a truthy result — a false stays re-queried.

Consumers: `core/selfhost/controller.ts` and `core/selfhost/setup.ts` (redirect to/from
`/admin/setup`), and the `initialized` field on the server-config GraphQL resolver.

## G8 — A minimal Nest context is viable for the CLI gate

`PrismaFactory` (`src/base/prisma/factory.ts`) takes exactly one dependency, `Config`, and
`ConfigModule` (`src/base/config/index.ts`) is `@Global` with just `ConfigProvider` and
`ConfigFactory`. `src/base/prisma/config.ts` registers the `db` module config with
`datasourceUrl` bound to `DATABASE_URL`.

So `ConfigModule` + `PrismaModule` is a two-module graph with no Redis, Manticore, or job
runner. `db check` can boot on it and cannot fail for unrelated infrastructure reasons.

By contrast `CliAppModule` (`src/data/app.ts`) imports `...FunctionalityModules` **plus**
`IndexerModule` — far too much to stand behind a safety gate, and the reason `withMinimalApp` is
a new helper rather than a reuse of `withCliApp`.

## G9 — Existing CLI shape

`src/cli.ts` builds a `commander` program with `create`, `run`, `revert`, `import-config`, each
wrapped in `withCliApp`. It already does `program.exitOverride()` and maps `CommanderError` to
`process.exitCode`, so a non-zero exit from a new `db check` needs no new plumbing.

`yarn cli` is `cross-env SERVER_FLAVOR=script node ./dist/main.js`; `src/index.ts` dispatches on
`env.flavors.script` to `runCli()` instead of `runServer()`. `yarn predeploy` is
`yarn prisma migrate deploy && yarn cli run`, and `self-host-predeploy.js` drives the same two
steps via `execSync` — the idiom a `runCompatGate()` call slots into.

## G10 — Fork guard obligations

`scripts/woven-manifest-guard.sh` (bead `affine-hn1.2`) fails CI on any changed file that
**also exists at the upstream baseline** in `scripts/woven-upstream-baseline` unless
`scripts/woven-patch-manifest.md` carries a row for it. Ownership is decided mechanically, not
by a path allowlist, so the three upstream-owned files this plan touches (`cli.ts`,
`app.module.ts`, `self-host-predeploy.js`) each need a row. Files under a new fork-owned
`src/core/db-compat/` do not.

The same manifest's merge-checklist step 2 already names the CONTRACT-migration hazard and
points at `affine-tc6`, while admitting it is "a prompt to a human, not the guard item 1 asks
for" — T6 replaces that prompt with `yarn cli db status`.
