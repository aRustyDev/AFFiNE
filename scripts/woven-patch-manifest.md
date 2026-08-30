# Woven fork — patch manifest

Deliverable of bead **affine-hn1** (upstream merge & fork-drift management). This file is the
tracked list of every **upstream-owned** file the Woven fork deliberately diverges on, with
rationale and category. Categories come from **affine-cm9** (fork strategy):

| Category                  | Meaning                                                                                          | Upstreamable? |
| ------------------------- | ------------------------------------------------------------------------------------------------ | ------------- |
| **ADDITIVE**              | New fork-owned files (`scripts/woven-*`, new plugins/modules/blocks, config flags). Rebase-safe. | Sometimes     |
| **FORK-LOCAL CORE PATCH** | Changes upstream _behavior_ — member/seat limits, core auth/quota/permission.                    | **NEVER**     |

Only **upstream-owned** files belong in the table below. Fork-owned additions are rebase-safe by
construction and are not tracked here — the CI guard's job is to fail when an upstream-owned file
is modified _without_ a row here.

That guard is **`scripts/woven-manifest-guard.sh`** (bead `affine-hn1.2`), run on every PR into
`woven/main` by `.github/workflows/woven-manifest-guard.yml`. It decides ownership mechanically
rather than by a path allowlist: a changed file is upstream-owned iff it also **exists at the
upstream baseline** recorded in `scripts/woven-upstream-baseline`. It fails on an unmanifested
upstream-owned change, and on a row whose path no longer exists in the tree. Run it locally before
pushing:

```bash
scripts/woven-manifest-guard.sh
```

This file is therefore no longer advisory prose. It was: `affine-hn1.1` shipped a version of it
that omitted `packages/backend/server/src/seed/index.ts` even though that commit's own audit had
named the file, and only a human re-reading caught it. `scripts/woven-manifest-guard.test.sh`
keeps that exact miss as a regression fixture.

## Diverged upstream-owned files

| File                                                          | Category                  | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Delete when                                                                                      |
| ------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `packages/backend/server/src/plugins/oauth/providers/oidc.ts` | **FORK-LOCAL CORE PATCH** | OIDC must reach an internal, **org-CA-signed** issuer (Zitadel `id.auth.woven`). `safeFetch` is the native Rust path (`base/utils/ssrf.ts` → `native/src/safe_fetch.rs` → the `safefetch` crate), built on rustls with **no native-certs feature**, so it trusts webpki roots only and **ignores `NODE_EXTRA_CA_CERTS`**. The patch routes OIDC discovery, JWKS and token/userinfo through Node `fetch`, which does honor it. Touches core auth behavior ⇒ never upstream.                                                                                                             | `affine-mbv` (hardened outbound fetch service) lands with **configurable CA trust**              |
| `.github/workflows/build-test.yml`                            | **ADDITIVE**              | Adds `workflow_dispatch:` to the `on:` block, nothing else. Upstream's `push:` list covers only its own release branches, so `woven/main` has no automatic run of this workflow while `woven-publish-image.yml` _does_ fire on it — a fork merge can therefore reach GHCR untested, which is what happened to the v0.27.4 sync. One added trigger, no job or step changes, so it is low-conflict on future merges and is a plausible upstream contribution.                                                                                                                            | upstream gains its own `workflow_dispatch`, or `woven/main` is added to a `push:` list           |
| `packages/backend/server/src/seed/index.ts`                   | **ADDITIVE**              | Adds a fork-local `WovenWorkspace` composite to the `seed` CLI (owner + members + one root-doc workspace), delegating to `__tests__/fixtures/woven-workspace.ts`, plus the matching help text. Intercepts before the `Mockers` registry lookup because the composite is not a single Mocker. **Dev/test tooling only — it changes no runtime product behavior**, which is why this is ADDITIVE and not a core patch. Was MISSED when this manifest was first written (`eac15e21bd` listed only `oidc.ts`) even though the divergence audit had identified it; added at `affine-hn1.1`. | the composite moves to a fork-owned file that upstream's `seed` CLI can discover without an edit |

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
   OAuth. `woven-manifest-guard.yml` runs on this same `pull_request:` trigger, for the same
   reason — a guard wired to `push:` would never fire on this fork.
8. Merging to `woven/main` triggers `woven-publish-image.yml` → GHCR. The consuming infra repo then
   re-pins the image **digest** (GHCR `woven-<sha>` tags are mutable).
