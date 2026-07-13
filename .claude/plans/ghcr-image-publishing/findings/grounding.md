# Grounding — ghcr-image-publishing (verified 2026-07-13)

Authored against `woven/main` (fork HEAD near commit `60ed1489c`). Pointers are
discovery descriptions, not `file:line`.

## G1 — Fork remotes + branch
- `origin` = `git@github.com:aRustyDev/AFFiNE.git` (fetch + push); `upstream` =
  `git@github.com:toeverything/AFFiNE.git` (push DISABLED). Branch `woven/main`.
- ⇒ GHCR namespace for the fork = **`ghcr.io/arustydev/affine`** (GHCR lowercases the
  owner; `${{ github.repository_owner }}` = `aRustyDev`).

## G2 — Upstream image pipeline (what we adapt, not edit)
- `.github/workflows/build-images.yml` is a **reusable** (`workflow_call`) job graph:
  build `@affine/web`, `@affine/admin`, `@affine/mobile`, `@affine/server-native`
  (matrix x64/arm64/armv7), `@affine/server` → then **`build-images`** logs in to
  `ghcr.io` (`username: github.actor`, `password: GITHUB_TOKEN`, `packages: write`) and
  `docker/build-push-action` builds `platforms: linux/amd64,linux/arm64,linux/arm/v7`
  from **`.github/deployment/node/Dockerfile`**, pushing
  `ghcr.io/toeverything/affine:${build-type}-${git-short-hash}`.
- Driven by **`.github/workflows/release.yml`** (scheduled `cron: 0 9 * * *` +
  `workflow_dispatch`) — the whole web/desktop/mobile release surface.
- **Registry owner is hardcoded** to `toeverything` in the tags line → the core change is
  deriving it from `github.repository_owner`.

## G3 — Secrets the upstream build reads (and what's optional)
- `build-web`/`admin`/`mobile` read: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY` (source-map upload to R2), `SENTRY_*`, `CAPTCHA_SITE_KEY`,
  `PERFSEE_TOKEN`. `build-server-native` reads `AFFINE_PRO_PUBLIC_KEY`,
  `AFFINE_PRO_LICENSE_AES_KEY` (the licensed/Pro native build).
- Hypothesis (confirm in A0): R2/Sentry/Perfsee/Captcha are **telemetry/source-map/anti-bot
  uploads** — empty ⇒ the build still produces a working self-host bundle. `AFFINE_PRO_*`
  gates the **licensed** native addon → omit for a **community/self-host** image.
- The `build-images` job also uses `npm.pkg.github.com` scope `@toeverything` for private
  packages during `yarn workspaces focus @affine/server --production` — confirm the fork
  can resolve these with `GITHUB_TOKEN` (A0 risk).

## G4 — The fork's EXISTING CD is local-only (do not conflate)
- `scripts/woven-build-image.sh` + `woven.Dockerfile` build `woven/affine:<sha>` **from
  source, locally, no registry** (build DEFERRED per `.beads/woven-cd-gate.md` §9).
- `scripts/woven-promote.sh stage|prod|rollback` promotes that local image into the
  **`woven-local` compose** stack (the Mac), resolving the live target *by identity*.
- Bead **`affine-yiz`** (IN PROGRESS) = "first CD cutover: AFFINE_IMAGE override +
  from-source build + stage + prod" — **local compose**, not GHCR, not k3s.
- ⇒ This epic is the **registry/CI** track; A3 reconciles the two so the image the cluster
  pulls and the image the compose promotes are consistent.

## G5 — Upstream Helm chart is NOT our deploy path
- `.github/helm/affine/` is a **GCP cloud** umbrella chart (`platform: gcp`,
  `cloud.google.com/backend-config`, `gcloud-sql-proxy` subchart, graphql/front/doc/sync/
  renderer/web split, `deployment.type: 'affine'`). Its own comment says it is not
  self-host ready. The k3s deploy uses the **single self-host container** via the
  separate `helm-charts/charts/affine` chart — see the infra plan. We only produce the
  **image** here.

## G6 — Dockerfile + arch
- `.github/deployment/node/Dockerfile` is the self-host server image builder (consumes the
  prebuilt `server/dist` + web/admin/mobile artifacts + `server-native` `.node`).
- Target arch should match ds-cleaner (infra OQ-3; expect amd64). Dropping arm/v7 (and
  likely arm64) cuts the server-native matrix and QEMU cross-build time substantially.

## G7 — Repo hygiene
- Root `*.md` is git-ignored (`.gitignore` `/*.md`) but **`.claude/` is NOT ignored**
  (`git check-ignore` clean) → this plan under `.claude/plans/**` tracks normally.
- Runtime CD markers use `.git/info/exclude`, not the tracked `.gitignore`.
- Conservative profile (bootstrap §5): no `git commit`/`push`/`bd dolt push` without
  explicit operator authority.
