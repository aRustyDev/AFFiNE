# Decision log — ghcr-image-publishing

- **D1 — Public GHCR package.** Operator call 2026-07-13 (mirrors infra D2). Cluster
  pulls `ghcr.io/arustydev/affine` anonymously; no pull secret. Accepts public visibility
  of fork-local patches. *Status: accepted.*
- **D2 — New fork-local workflow; do not edit upstream `build-images.yml`/`release.yml`.**
  Editing shared upstream workflows forks them and breaks weekly `canary` rebases
  (`affine-hn1`). Add `woven-publish-image.yml`, derive owner from
  `github.repository_owner`. *Status: accepted.*
- **D3 — Self-host server image only.** Build web+admin+server(+server-native); skip
  mobile/desktop. The ds-cleaner chart runs the single self-host container. *Status: accepted.*
- **D4 — Build without proprietary secrets.** Omit R2/Sentry/Perfsee/Captcha (telemetry/
  source-map/anti-bot) and `AFFINE_PRO_*` (licensed native) → community/self-host image.
  A0 spike confirms exactly what breaks with them empty. *Status: accepted, pending A0.*
- **D5 — Tags: immutable `woven-<short-sha>` + moving `:woven`.** Cluster pins the
  immutable ref; `:woven` for humans. OCI `image.source` → fork repo. *Status: accepted.*
- **D6 — Arch = cluster arch (expect amd64).** Confirm via infra OQ-3; drop arm/v7 and
  likely arm64 for CI speed; multi-arch later. *Status: accepted, pending confirmation.*
- **D7 — Trigger: push to `woven/main` + `workflow_dispatch`.** Not the upstream daily
  cron (that carries the whole desktop/mobile release surface). *Status: accepted.*

## Spike results — `affine-3ab.1` (A0), 2026-07-13

Two rungs run (operator ladder: local → scratch CI → published CI):

- **Rung 1 — local arm64 recipe smoke (GREEN).** Built `woven/affine:834482899` from
  `scripts/woven.Dockerfile` unmodified in ~9 min (arm64, 244 MB content). Boots and is
  runnable (fails only on absent Redis).
- **Rung 2 — scratch CI amd64, build-only (`push:false`) (GREEN).** `woven-publish-image.yml`
  built the amd64 image on a stock `ubuntu-latest` runner in ~24 min. Runner root = 145 G
  (109 G free after reclaim); **no disk/RAM/time pressure → the upstream parallel matrix
  fallback is NOT needed.**

Open questions resolved by the spike:

- **OQ-1 (build without proprietary secrets) → RESOLVED.** Web/admin/mobile/server build
  clean with `R2_*`/`SENTRY_*`/`PERFSEE_*`/`CAPTCHA_SITE_KEY` empty and `AFFINE_PRO_*`
  unset. **No leg needs gating or stubbing** (log shows `CAPTCHA_SITE_KEY:""`,
  `SENTRY_DSN:""` and the build proceeds). D4 confirmed.
- **OQ-2 (reuse upstream reusable workflow vs fork the matrix) → RESOLVED: neither —
  reuse the fork's own `scripts/woven.Dockerfile`.** A single monolithic from-source build
  (rust native + web/admin/server) replaces upstream's 5-job artifact-passing matrix, needs
  no `@toeverything` npm scope wiring, and is already `woven-*`/rebase-safe. One
  `buildx build`. This is simpler than both D2 options and fits CI.
- **OQ-3 (`@toeverything` private packages) → RESOLVED: no token needed.** `.yarnrc.yml`
  uses public `registry.npmjs.org` with no scope override; `yarn install --immutable`
  resolved all deps with no `GITHUB_TOKEN`/npm auth in both rungs.
- **D6 (arch) confirmed:** amd64 builds cleanly in CI (`docker-clean.mjs` maps `amd64→x64`);
  `woven.Dockerfile` made `TARGETARCH`-aware so amd64 (cluster) + arm64 (local) both build.
- **Latent bug found → bead `affine-4aj`:** `woven-build-image.sh` copies
  `scripts/woven.dockerignore` to a temp name BuildKit never reads (so the committed root
  `.dockerignore` has silently governed the local build); and `woven.dockerignore` excludes
  `tests/`, which — if actually applied — drops 8 `tests/*` workspaces and fails
  `yarn --immutable` with `YN0028` (hit live in scratch run `29293390322`, fixed by using
  the root `.dockerignore`).
