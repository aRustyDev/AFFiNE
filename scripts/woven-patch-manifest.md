# Woven fork — patch manifest

Deliverable of bead **affine-hn1** (upstream merge & fork-drift management). This file is the
tracked list of every **upstream-owned** file the Woven fork deliberately diverges on, with
rationale and category. Categories come from **affine-cm9** (fork strategy):

| Category                  | Meaning                                                                                                                                               | Upstreamable? |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| **ADDITIVE**              | Adds to an upstream-owned file without changing upstream _behavior_ — a new workflow trigger, a fork-only composite in a dev/test CLI, a config flag. | Sometimes     |
| **FORK-LOCAL CORE PATCH** | Changes upstream _behavior_ — member/seat limits, core auth/quota/permission.                                                                         | **NEVER**     |

Both categories are divergences on **upstream-owned** files, and neither is rebase-safe — every row
here is something the next upstream merge can silently drop or resurrect, which is why the table
exists. The category does not record how risky a merge is; it records **upstreamability**, and that
turns on the one question above: does the change alter upstream's behavior? A brand-new fork-owned
file is therefore _not_ ADDITIVE — it belongs to no category here at all, because it is not tracked
in this table (see below).

A row also carries a **State** (`affine-83p`), declaring whether the fork's own edit is present in
the tree, or is itself a deletion or rename:

| State                | Meaning                                                                               |
| -------------------- | ------------------------------------------------------------------------------------- |
| _(empty)_            | The file is present in the tree and diverges from upstream. The default.              |
| **REMOVED**          | This fork deletes the upstream-owned file. The row stays; absence is the declaration. |
| **MOVED** `new/path` | This fork relocates it. The destination is checked, and inherits the row's category.  |

A deletion or rename is still a divergence — arguably the most rebase-dangerous
kind, because an upstream edit to a file the fork deleted resurrects it on the
next merge. Declare it here rather than dropping the row (`affine-83p`).

Only **upstream-owned** files belong in the table below. Fork-owned additions are rebase-safe by
construction and are not tracked here — the CI guard's job is to fail when an upstream-owned file
is modified _without_ a row here.

That guard is **`scripts/woven-manifest-guard.sh`** (bead `affine-hn1.2`), run by
`.github/workflows/woven-manifest-guard.yml` — on every PR into `woven/main` (inbound), and on every
push to an `upstream/**` branch (outbound, `--outbound`, bead `affine-hn1.4`). It decides ownership mechanically
rather than by a path allowlist: a changed file is upstream-owned iff it also **exists at the
upstream baseline** recorded in `scripts/woven-upstream-baseline`. It fails on an unmanifested
upstream-owned change, and on a row whose path no longer exists in the tree. Run it locally before
pushing:

```bash
scripts/woven-manifest-guard.sh
```

The same script enforces the **outbound** direction with `--outbound` (bead
`affine-hn1.4`): it fails when a change set touches a file whose row says
**FORK-LOCAL CORE PATCH**, which `affine-cm9` requires never reach upstream. That
makes column 2 load-bearing — a row's category is now enforced, not documentation.
An unrecognised category exits 2 rather than being assumed ADDITIVE.

Outbound only judges a branch that is already **inbound-clean**: it runs the same
unmanifested-row and stale-row checks the default direction runs, and refuses to
judge a branch that fails them. A manifest row the parser cannot read would
otherwise silently drop its file out of the FORK-LOCAL set, so the leak check
would pass by omission; requiring inbound-clean first means that class of parser
gap fails closed instead. `--dump-rows` prints exactly what the parser and
classifier saw for each row — tab-separated path, resolved category, resolved
State, and a `MOVED` row's destination (empty otherwise) — or the raw line if it
did not parse. Useful for debugging a rejected row, or for confirming a path is
paired with the category and State you expect.

To prepare a contribution for upstream, do not branch from `woven/main` — it
carries every fork-local patch the fork has ever made. Use:

```bash
scripts/woven-upstream-branch.sh [--from REF] [--no-switch] <name> <path>...
```

It branches from `UPSTREAM_COMMIT`, carries over only the files you name, and
names the branch `upstream/<name>` — the prefix the CI backstop keys on.

This file is therefore no longer advisory prose. It was: `affine-hn1.1` shipped a version of it
that omitted `packages/backend/server/src/seed/index.ts` even though that commit's own audit had
named the file, and only a human re-reading caught it. `scripts/woven-manifest-guard.test.sh`
keeps that exact miss as a regression fixture.

## Diverged upstream-owned files

| File                                                          | Category                  | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Delete when                                                                                                      | State |
| ------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----- |
| `packages/backend/server/src/plugins/oauth/providers/oidc.ts` | **FORK-LOCAL CORE PATCH** | OIDC must reach an internal, **org-CA-signed** issuer (Zitadel `id.auth.woven`). `safeFetch` is the native Rust path (`base/utils/ssrf.ts` → `native/src/safe_fetch.rs` → the `safefetch` crate), built on rustls with **no native-certs feature**, so it trusts webpki roots only and **ignores `NODE_EXTRA_CA_CERTS`**. The patch routes OIDC discovery, JWKS and token/userinfo through Node `fetch`, which does honor it. Touches core auth behavior ⇒ never upstream.                                                                                                                                                                                                                                                                                                                                                                    | `affine-mbv` (hardened outbound fetch service) lands with **configurable CA trust**                              |       |
| `.github/workflows/build-test.yml`                            | **ADDITIVE**              | Adds `workflow_dispatch:` to the `on:` block, nothing else. Upstream's `push:` list covers only its own release branches, so `woven/main` has no automatic run of this workflow while `woven-publish-image.yml` _does_ fire on it — a fork merge can therefore reach GHCR untested, which is what happened to the v0.27.4 sync. One added trigger, no job or step changes, so it is low-conflict on future merges and is a plausible upstream contribution.                                                                                                                                                                                                                                                                                                                                                                                   | upstream gains its own `workflow_dispatch`, or `woven/main` is added to a `push:` list                           |       |
| `packages/backend/server/src/seed/index.ts`                   | **ADDITIVE**              | Adds a fork-local `WovenWorkspace` composite to the `seed` CLI (owner + members + one root-doc workspace), delegating to `__tests__/fixtures/woven-workspace.ts`, plus the matching help text. Intercepts before the `Mockers` registry lookup because the composite is not a single Mocker. **Dev/test tooling only — it changes no runtime product behavior**, which is why this is ADDITIVE and not a core patch. Was MISSED when this manifest was first written (`eac15e21bd` listed only `oidc.ts`) even though the divergence audit had identified it; added at `affine-hn1.1`.                                                                                                                                                                                                                                                        | the composite moves to a fork-owned file that upstream's `seed` CLI can discover without an edit                 |       |
| `.docker/selfhost/schema.json`                                | **ADDITIVE**              | Generated by `yarn affine server genconfig`; carries the three `woven.selfhost*` config descriptors because `core/quota/state.ts` imports the fork-owned `woven-config.ts`. **Regenerate, never hand-edit.**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | the woven config module is removed                                                                               |       |
| `packages/frontend/admin/src/config.json`                     | **ADDITIVE**              | Generated by `yarn affine server genconfig`; carries the three `woven.selfhost*` config descriptors because `core/quota/state.ts` imports the fork-owned `woven-config.ts`. **Regenerate, never hand-edit.**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | the woven config module is removed                                                                               |       |
| `packages/backend/server/src/core/quota/state.ts`             | **FORK-LOCAL CORE PATCH** | Makes the three hardwired `selfhost_free` quotas configurable — member cap (10), storage quota (100GB), per-file blob limit (100MB) — by flooring the resolved quota object at both `reconcile*QuotaStateNow` sites. All logic is in the fork-owned `core/quota/woven-config.ts`; only the two call sites, the `Config` injection and one import are upstream-owned. Defaults (`-1`) inherit the plan value, so an unconfigured server is byte-identical to upstream. Core quota/permission behavior ⇒ never upstream. Bead `affine-vap`; design `.claude/plans/selfhost-quota-limits/DESIGN.md`.                                                                                                                                                                                                                                             | upstream ships configurable self-host quotas (env or `AppConfig`) for member limit, storage quota and blob limit |       |
| `packages/backend/server/src/server.ts`                       | **ADDITIVE**              | Adds one `await assertDatabaseCompatible(app, logger)` call between `NestFactory.create()` and `app.listen()`, for the `affine-tc6` boot-time compatibility guard. That placement is load-bearing, not incidental: `NestFactory.create()` runs no lifecycle hooks at all, so it strictly precedes every module `onApplicationBootstrap` hook — including the native migration runners in `BackendRuntimeProvider` and `StorageRuntimeProvider` — and it runs before `app.listen()`'s callback would flush the `bufferLogs: true` buffer set up above, which is why a refusal's full report travels in the thrown `Error`'s message rather than relying on the logger. `src/index.ts` dispatches to either `runCli()` or this file's `runServer()`, so the check is structurally unreachable from the CLI — no module-graph subtlety required. | upstream grows its own boot-time schema-compatibility check                                                      |       |
| `packages/backend/server/src/cli.ts`                          | **ADDITIVE**              | Adds a `db` command group (`db status`, `db check`, `db stamp`) and a `withMinimalApp` helper that boots a config+prisma-only context, for the `affine-tc6` database-compatibility gate. Pure addition — no existing command or the shared `withCliApp` is touched, so it is low-conflict on upstream merges. Fork-owned logic all lives in `src/core/db-compat/`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | upstream grows its own migration-compatibility gate                                                              |       |
| `packages/backend/server/src/app.module.ts`                   | **ADDITIVE**              | One added import: `DbCompatModule` (the `affine-tc6` compat SERVICE only — no bootstrap hook, no side effects) in `AppModule`'s `imports`, so `server.ts`'s `assertDatabaseCompatible` can resolve `DbCompatService` via `app.get()`. An earlier revision instead added a `DbCompatGuardModule` running the check from an `OnApplicationBootstrap` hook; that hook ran AFTER `BackendRuntimeProvider`'s and `StorageRuntimeProvider`'s own bootstrap hooks, both of which call native `runMigrations()` — so the guard lost the race against exactly the mutation it existed to prevent. The check now runs in `server.ts` instead (see that row), and this import exists only to make the service reachable there. One line, low-conflict.                                                                                                   | upstream grows its own boot-time schema-compatibility check                                                      |       |
| `packages/backend/server/scripts/self-host-predeploy.js`      | **ADDITIVE**              | Adds `runCompatGate()` (`yarn cli db check`) after `fixFailedMigrations()` and before `runPrismaMigrations()` — the ordering is required, not incidental: gating first would return `MIGRATION_FAILED` on exactly the databases `fixFailedMigrations()` exists to heal, wedging those upgrades permanently. Plus `recordAdoption()` (`yarn cli db stamp`) after the migrations, since the stamp lives in `app_configs`, which does not exist on a fresh install until they have run (D17). Both real deployment paths already invoke this script — the k8s initContainer and the self-host compose one-shot — which is why the `affine-tc6` gate needs no infrastructure change.                                                                                                                                                              | upstream's predeploy grows an equivalent guard                                                                   |       |

### `oidc.ts` — measured justification

Do **not** re-justify this patch with SSRF. Upstream `d24c17f300` (#15271) added
`OAuthOIDCProviderConfig.allowPrivateNetwork` plus a `fetchOptions()` override granting
`allowPrivateTargetOrigin` when the target origin matches the issuer — so `blocked_ip` is
**upstream-solved**. TLS trust is the _only_ surviving reason.

Measured on `ghcr.io/toeverything/affine:stable`, calling the shipped native module directly,
`allowPrivateTargetOrigin: true` throughout, with a public-host control:

| Target           |             | native `safeFetch` | Node `fetch`                                    |
| ---------------- | ----------- | ------------------ | ----------------------------------------------- |
| `cloudflare.com` | no CA       | OK 200             | OK 200                                          |
| `cloudflare.com` | with CA     | OK 200             | OK 200                                          |
| `id.auth.woven`  | no CA       | FAIL               | FAIL (`unable to get local issuer certificate`) |
| `id.auth.woven`  | **with CA** | **FAIL**           | **OK 200**                                      |

The cert chain is the only variable, so this is a trust failure — not a network or harness
artifact. Re-run this before deleting the patch.

## Merge-time checklist (affine-hn1)

1. `git merge <upstream release tag>` from `woven/main`. Prefer a **stable tag** over `canary`.
2. **Audit incoming migrations for destructive DDL** — `packages/backend/server/migrations/` and
   `src/data/migrations/`. A CONTRACT migration (DROP / retype / tighten) makes image rollback
   impossible: per `affine-tc6` there is no "database is newer than me, refuse to start" guard and
   no down-migration path. Require a verified-restorable backup before deploying across one.
3. **Resolve conflicts, then re-read the whole file.** A trivial textual conflict can hide a
   semantic break: upstream may delete a symbol fork code still references, and git takes the
   deletion cleanly. `v0.27.4` did exactly this with `OIDC_FETCH_OPTIONS`.
4. **Account for `src/schema.gql`.** It is emitted by NestJS `autoSchemaFile` **when the server
   boots** — there is no standalone codegen script, so "regenerating" it means running the full
   stack (yarn install + Rust native build + Postgres). Two acceptable outcomes: regenerate it, or
   **prove regeneration is a no-op** — the file is byte-identical to the upstream tag _and_ no
   fork-owned file carries a GraphQL decorator (`@Resolver`/`@ObjectType`/`@InputType`/`@Field`/
   `@Query`/`@Mutation`/`@Subscription`/`@ArgsType`/`@InterfaceType`/`registerEnumType`). Record
   which one you did.
5. **Re-point the baseline, then update this manifest if the diverged set changed.** Set
   `UPSTREAM_TAG` / `UPSTREAM_COMMIT` in `scripts/woven-upstream-baseline` to the tag you merged
   and its commit (`git rev-parse <merge>^2`) **in the same commit as the merge** — the guard reads
   the commit, not the tag, because upstream's tags are not pushed to this fork's origin. Then run
   `scripts/woven-manifest-guard.sh` until it is clean. It tells you exactly which paths need a row.
6. **Run the plan-drift sweep before calling the merge done** (`affine-3os`, wired here by
   `affine-hn1.3`). `affine-3os` requires a sweep over open work after every upstream merge and
   every merged PR; for `v0.27.4` it did not run, and a hand audit five days later found drift that
   had been sitting unflagged. Run:

   ```bash
   scripts/woven-drift-sweep.sh            # beads citing a file this merge changed
   bd lint                                  # read the task/feature/bug rows ONLY
   ```

   The sweep is advisory — it lists candidates, you make the calls. Read each one against the diff
   (`git diff --name-only <baseline> HEAD`) for the three drift classes the 2026-08-29 audit
   actually found:

   - **(a) satisfied** — an _open_ bead whose acceptance criteria this merge already meets. Close
     it with the evidence. `affine-hn1.1` was fully satisfied and still open.
   - **(b) invalidated** — an _in_progress_ bead whose analysis the merge broke: a stale image or
     SHA, a moved path, a new migration its safety argument never accounted for. Reset it to open
     and say in the notes that the plan is **invalid, not merely paused**. `affine-yiz` had sat 54
     days on an image 117 commits stale, with a new CONTRACT migration it never accounted for.
   - **(c) incidental** — a bead whose fix landed as a side effect of an unrelated commit, with
     nothing written on the bead. Record what was fixed and what is still open. `affine-4aj` was
     half-fixed by `4384cd820c` and nobody noted it.

   On `bd lint`, ignore the epic warnings. 24 of them are epics missing `## Success Criteria`, and
   `affine-3os` deliberately keeps epics thin until they enter the execution horizon — that class
   is noise by design, so **do not gate CI on a clean lint**. Repeat this step after the PR merges.

7. **Open a PR to run CI.** `build-test.yml`'s `push:` trigger covers only
   `canary`/`beta`/`stable`/`v*.x` — **not** `woven/*` — so pushing a `woven/` branch runs nothing.
   The suite runs on `pull_request:`. Target `src/__tests__/oauth/controller.spec.ts` for auth
   changes; `woven-ci-min.sh`'s default glob (`src/core/quota/__tests__/*.spec.ts`) does not cover
   OAuth. `woven-manifest-guard.yml` runs its inbound check on this same `pull_request:` trigger,
   for the same reason. It **also** runs on `push:` to `upstream/**` (`affine-hn1.4`) — that
   second trigger enforces the opposite direction (a fork-local patch must never reach upstream)
   and is a fork-owned workflow free to declare its own `push:` branches, unlike `build-test.yml`,
   whose trigger list is upstream's.
8. Merging to `woven/main` triggers `woven-publish-image.yml` → GHCR. The consuming infra repo then
   re-pins the image **digest** (GHCR `woven-<sha>` tags are mutable).
