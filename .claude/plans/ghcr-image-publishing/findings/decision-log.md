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
