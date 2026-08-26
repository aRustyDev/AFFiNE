# Woven fork — patch manifest

Deliverable of bead **affine-hn1** (upstream merge & fork-drift management). This file is the
tracked list of every **upstream-owned** file the Woven fork deliberately diverges on, with
rationale and category. Categories come from **affine-cm9** (fork strategy):

| Category | Meaning | Upstreamable? |
|---|---|---|
| **ADDITIVE** | New fork-owned files (`scripts/woven-*`, new plugins/modules/blocks, config flags). Rebase-safe. | Sometimes |
| **FORK-LOCAL CORE PATCH** | Changes upstream *behavior* — member/seat limits, core auth/quota/permission. | **NEVER** |

Only **upstream-owned** files belong in the table below. Fork-owned additions are rebase-safe by
construction and are not tracked here — the CI guard's job is to fail when an upstream-owned file
is modified *without* a row here.

## Diverged upstream-owned files

| File | Category | Why | Delete when |
|---|---|---|---|
| `packages/backend/server/src/plugins/oauth/providers/oidc.ts` | **FORK-LOCAL CORE PATCH** | OIDC must reach an internal, **org-CA-signed** issuer (Zitadel `id.auth.woven`). `safeFetch` is the native Rust path (`base/utils/ssrf.ts` → `native/src/safe_fetch.rs` → the `safefetch` crate), built on rustls with **no native-certs feature**, so it trusts webpki roots only and **ignores `NODE_EXTRA_CA_CERTS`**. The patch routes OIDC discovery, JWKS and token/userinfo through Node `fetch`, which does honor it. Touches core auth behavior ⇒ never upstream. | `affine-mbv` (hardened outbound fetch service) lands with **configurable CA trust** |
| `.github/workflows/build-test.yml` | **ADDITIVE** | Adds `workflow_dispatch:` to the `on:` block, nothing else. Upstream's `push:` list covers only its own release branches, so `woven/main` has no automatic run of this workflow while `woven-publish-image.yml` *does* fire on it — a fork merge can therefore reach GHCR untested, which is what happened to the v0.27.4 sync. One added trigger, no job or step changes, so it is low-conflict on future merges and is a plausible upstream contribution. | upstream gains its own `workflow_dispatch`, or `woven/main` is added to a `push:` list |

### `oidc.ts` — measured justification

Do **not** re-justify this patch with SSRF. Upstream `d24c17f300` (#15271) added
`OAuthOIDCProviderConfig.allowPrivateNetwork` plus a `fetchOptions()` override granting
`allowPrivateTargetOrigin` when the target origin matches the issuer — so `blocked_ip` is
**upstream-solved**. TLS trust is the *only* surviving reason.

Measured on `ghcr.io/toeverything/affine:stable`, calling the shipped native module directly,
`allowPrivateTargetOrigin: true` throughout, with a public-host control:

| Target | | native `safeFetch` | Node `fetch` |
|---|---|---|---|
| `cloudflare.com` | no CA | OK 200 | OK 200 |
| `cloudflare.com` | with CA | OK 200 | OK 200 |
| `id.auth.woven` | no CA | FAIL | FAIL (`unable to get local issuer certificate`) |
| `id.auth.woven` | **with CA** | **FAIL** | **OK 200** |

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
   **prove regeneration is a no-op** — the file is byte-identical to the upstream tag *and* no
   fork-owned file carries a GraphQL decorator (`@Resolver`/`@ObjectType`/`@InputType`/`@Field`/
   `@Query`/`@Mutation`/`@Subscription`/`@ArgsType`/`@InterfaceType`/`registerEnumType`). Record
   which one you did.
5. Update this manifest if the diverged set changed.
6. **Open a PR to run CI.** `build-test.yml`'s `push:` trigger covers only
   `canary`/`beta`/`stable`/`v*.x` — **not** `woven/*` — so pushing a `woven/` branch runs nothing.
   The suite runs on `pull_request:`. Target `src/__tests__/oauth/controller.spec.ts` for auth
   changes; `woven-ci-min.sh`'s default glob (`src/core/quota/__tests__/*.spec.ts`) does not cover
   OAuth.
7. Merging to `woven/main` triggers `woven-publish-image.yml` → GHCR. The consuming infra repo then
   re-pins the image **digest** (GHCR `woven-<sha>` tags are mutable).
