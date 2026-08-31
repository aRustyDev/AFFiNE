# Woven fork of AFFiNE — agent bootstrap

> **FORK-LOCAL, canonical, tracked. Do not include this file (or anything it
> points to under `scripts/woven-*` / `.beads/`) in an upstream-directed PR.**
> This is the Woven fork of `toeverything/AFFiNE`. Read this once at the start of
> a session; it is the single place that tells you the toolchain, the pre-deploy
> gate, the fork policy, and the task workflow. Authored against commit
> `5b7f83a6e` (branch `canary`); if a path or command below no longer matches
> HEAD, fix the reference as your first step (see "Definition-of-Ready" pointer).
>
> The repo root `AGENTS.md` is a thin pointer to this file (root `*.md` is
> git-ignored, so this `scripts/` copy is the durable, clone-surviving source).

## 0. Prime directive: fork-local vs upstream

This is a **hybrid fork** (decision `affine-cm9`):

- **Default to ADDITIVE changes** — new `src/plugins/woven-*`, new frontend/core
  modules, new blocks/property types, config flags, test fixtures. These stay
  rebase-safe against weekly upstream `canary` merges and some are even
  upstreamable.
- **A small set of FORK-LOCAL CORE PATCHES must NEVER be sent upstream** — first
  and foremost the **member/seat-limit removal** (`affine-vap`), plus any change
  to core auth/quota/permission behavior. Keep them isolated and clearly marked.

If you are ever unsure whether a change is upstreamable, it is fork-local until a
human says otherwise. Woven-specific files are namespaced (`woven-*`) or marked
with a `WOVEN FORK-LOCAL` banner so the eventual upstream-leak CI guard
(`affine-hn1`) can exclude them.

## 1. Toolchain

| Tool  | Version                                       | How to get it                       | Notes                                                                                                                                                                                                    |
| ----- | --------------------------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Node  | **22.23.x** (`.nvmrc`; engines `>=22.12 <23`) | `brew install node@22` (keg-only)   | System node may be newer and is rejected by AFFiNE. Put it on PATH **for the shell only** — do not touch your rc: `export PATH="$(brew --prefix node@22)/bin:$PATH"`. The gate script does this for you. |
| Yarn  | **4.13.0**                                    | bundled corepack: `corepack yarn …` | From `packageManager`. Set `COREPACK_ENABLE_DOWNLOAD_PROMPT=0`.                                                                                                                                          |
| Rust  | **1.96.0**                                    | pre-existing (Homebrew)             | Matches `rust-toolchain.toml`. Only needed to build native addons, not the gate.                                                                                                                         |
| cmake | any recent                                    | `brew install cmake`                | Needed by `@affine/native` (desktop). **Not** needed for the server/gate path.                                                                                                                           |

Install (once): `ELECTRON_SKIP_BINARY_DOWNLOAD=1 HUSKY=0 corepack yarn install`.

## 2. Disposable dev/test stack (NEVER the live stack)

Server tests **`TRUNCATE` the database**. They must only ever point at a
throwaway DB.

- Bring up (project `affine_dev_services`, fully separate from anything live):
  ```
  docker compose -f .docker/dev/compose.yml --env-file .docker/dev/.env up -d postgres redis mailpit
  ```
  postgres → `localhost:5432`, redis → `localhost:6379`, mailpit → `1025/8025`.
  (Both `.docker/dev/compose.yml` and `.env` are git-excluded; copy from the
  `*.example` if missing.)
- 🚨 **Server tests `TRUNCATE` the database.** Only ever point `DATABASE_URL` at
  the disposable stack (`localhost:5432`). `scripts/woven-ci-min.sh` enforces
  that the host is local and refuses anything else (override:
  `WOVEN_CI_FORCE=1`).

Standard environment for any test/gate/DB command:

```
export PATH="$(brew --prefix node@22)/bin:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export DATABASE_URL="postgresql://affine:affine@localhost:5432/affine"
export REDIS_SERVER_HOST=localhost
export AFFINE_INDEXER_ENABLED=false   # self-host parity; avoids needing Manticore
# NODE_ENV=test, DEPLOYMENT_TYPE=affine, MAILER_* are set by ava.config.js itself.
```

One-time DB setup against the disposable stack (idempotent; safe to re-run):

```
corepack yarn workspace @affine/server prisma generate
corepack yarn workspace @affine/server prisma migrate deploy   # applies all migrations
corepack yarn workspace @affine/server data-migration run       # NOT `cli run` (see gotchas)
```

## 3. The pre-deploy gate (two tiers)

Everything runs through **`scripts/woven-ci-min.sh`**, which sets the node@22
PATH, applies the env defaults above, and **refuses to run if `DATABASE_URL`
looks live** before running, in order and aborting on first failure:

1. `typecheck` (`tsc -b`)
2. `lint:ox` (`oxlint --deny-warnings`)
3. `codegen-drift` — regenerates i18n + bs-docs and fails if the tree changed
4. server AVA (targeted specs, `--forbid-only`)

**Minimal tier (fast, default) — what a fresh agent runs to validate a change:**

```
scripts/woven-ci-min.sh
```

**Full/pre-release tier — adds the heavy server e2e suite:**

```
scripts/woven-ci-min.sh --e2e          # or --full
```

You can target specific AVA specs: `scripts/woven-ci-min.sh 'src/core/quota/__tests__/*.spec.ts'`.

### Gotchas that will waste your time if you skip them

- **Run AVA via the wrapper** `yarn affine @affine/server test …` / `… e2e …`,
  **not** `yarn workspace @affine/server test`. The wrapper installs the TS/ESM
  loader; without it AVA cannot resolve `src/prelude.ts`.
- **Data migrations: `data-migration run`, not `cli run`.** `cli` is
  `node ./dist/main.js` and needs a built server; `data-migration` runs from
  source.
- **Codegen is `affine <workspace> build`** (`yarn affine @affine/i18n build`,
  `yarn affine bs-docs build`). There is no `gql`/`i18n`/`genconfig`
  subcommand. `i18n-completenesses.json` regenerates every run and is
  intentionally uncommitted — the gate `git checkout`s it.
- **macOS `/bin/bash` is 3.2** (no `mapfile`/`readarray`), and `timeout` /
  GNU-`zcat` are absent. The `woven-*` scripts are written 3.2-safe.

## 4. Seeding a test workspace

A shared, deterministic-shape fixture (owner + N accepted members + root doc)
lives in `packages/backend/server/src/__tests__/fixtures/woven-workspace.ts`
(`seedWovenWorkspace`). The **same helper** backs both:

- the seed CLI: `corepack yarn affine @affine/server seed WovenWorkspace`
  (`members=8n`, `id=…`, `email=…` overrides; run `seed --help` for all), and
- an e2e that asserts it persists:
  `packages/backend/server/src/__tests__/e2e/woven/workspace-fixture.spec.ts`.

The default seat count exceeds the old free-tier cap, so this fixture doubles as
the regression fixture for the member-limit removal (`affine-vap`). New e2e
files must live under `src/__tests__/e2e/**/*.spec.ts` and run with
`TEST_MODE=e2e` (i.e. via `yarn affine @affine/server e2e`).

## 5. Task workflow (beads)

Task tracking is **beads** (`bd`), not TodoWrite/markdown. The backlog DB for
this fork is `affine` on the shared Dolt server.

```
bd prime            # run first every session (recovers context after compaction)
bd ready            # work with no open blockers
bd show <id>        # full task: description / design / acceptance criteria
bd update <id> --claim
# … do the work; keep --notes current-state (COMPLETED/IN-PROGRESS/NEXT/BLOCKER) …
bd close <id>       # only when every acceptance box passes
```

- **Conservative profile**: do **not** `git commit`/`push` or `bd dolt push`
  without explicit authority from the user.
- File emergent work as its own bead: `bd create …` then
  `bd dep add <new> <current> --type discovered-from`.
- **Definition-of-Ready** for any task you author (decision `affine-knf`):
  Problem / Context / Why-now / **Pointers as discovery queries, not `file:line`
  (paths rot)** / `Authored against commit <sha>` / outcome-only acceptance
  criteria that are literal commands with expected output / a capability **tier**
  (not a model id). Related process decisions: `affine-3os` (rolling-wave),
  `affine-cm9` (fork strategy), `affine-tpb` (reuse platform seams — JobQueue /
  EventBus / config; don't rebuild them).

## 6. Code intelligence — GitNexus

A GitNexus code-knowledge-graph index named **`src-affine`** covers this repo;
prefer it over blind grep for "who calls / what breaks" questions. Query verbs:
`context` (what a symbol is + neighbors), `impact` (blast radius of a change),
`trace` (call/dependency paths). Confirm the exact invocation (MCP tool vs CLI)
in your environment before relying on it; it is an accelerator, not required for
the gate.

## 7. Deployment / CD

**There is no deploy step in this repo, and nothing here talks to the live
deployment.** Do not improvise one.

The pipeline is: merge to `woven/main` →
`.github/workflows/woven-publish-image.yml` builds `scripts/woven.Dockerfile`
and pushes `ghcr.io/arustydev/affine:woven-<sha>` (plus the floating `:woven`) →
the **`infrastructure`** repo (`products/affine/kube`) re-pins the image
**digest** — GHCR `woven-<sha>` tags are mutable, so the digest is authoritative
— and applies with OpenTofu. Deploy questions belong to that repo and its beads
DB (run `bd` from the `infrastructure` checkout).

Before merging, mind the manifest checklist step 2: a **CONTRACT** migration
(DROP / retype / tighten) makes image rollback impossible — per `affine-tc6`
there is no "database is newer than me, refuse to start" guard and no
down-migration path. Require a **verified-restorable** backup before deploying
across one. Backup/restore is a cluster-side (CNPG) concern; see
`docs/src/operations/affine-pg-restore-drill.md` in the infrastructure repo.

### Contributing back to upstream

`affine-cm9` allows ADDITIVE changes to be upstreamed and forbids FORK-LOCAL CORE
PATCHes from ever reaching `toeverything/AFFiNE`. Three things enforce that, all
calling `scripts/woven-manifest-guard.sh --outbound`:

1. `scripts/woven-upstream-branch.sh [--from REF] [--no-switch] <name> <path>...`
   — branches from the upstream baseline rather than `woven/main`, so the branch
   cannot carry a fork-local patch. Start here.
2. `.husky/pre-push` — refuses a push whose destination URL is `UPSTREAM_REPO`.
   Bypassable with `git push --no-verify`.
3. CI on push to `upstream/**` — the backstop for a push the hook did not see.

The prepared branch is a starting point: review, cherry-pick and squash it as
needed. The clean result the preparer reports describes the branch at creation,
not the branch you eventually push — which is why the last two exist.

`--outbound` only judges a branch that is already inbound-clean: it runs the
unmanifested-row and stale-row checks first and refuses to judge a branch that
fails them, so a manifest row the parser cannot read can never silently pass a
fork-local patch through. An unrecognised category in
`scripts/woven-patch-manifest.md` exits 2 rather than being assumed ADDITIVE.
`scripts/woven-manifest-guard.sh --dump-rows` shows exactly what the parser and
classifier saw for each row, if one of the three layers above refuses something
unexpectedly.
