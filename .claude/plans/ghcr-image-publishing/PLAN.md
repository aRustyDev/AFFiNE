# PLAN — ghcr-image-publishing (publish the Woven fork to ghcr.io/aRustyDev/AFFiNE)

> **FORK-LOCAL. Additive + `woven-*` namespaced per `affine-cm9` (fork strategy)
> and `affine-hn1` (upstream-leak guard). MUST NOT be sent upstream.**
> Status: **DRAFT — grounded 2026-07-13; beads epic filed. Not yet scheduled/
> implemented.** (The `affine` Dolt DB was migrated v49→v53 by the designated
> migrator on 2026-07-13, unblocking beads writes.)
> Beads: epic `affine-3ab` (affine DB), tasks `.1`–`.4` (A0–A3). Ships capability
> `affine-ghcr-image` (label `export:affine-ghcr-image` on `affine-3ab.3`),
> consumed cross-DB by infra epic `infra-bt6g` (`external:affine:affine-ghcr-image`).
> Decisions: [findings/decision-log.md](findings/decision-log.md) · Grounding:
> [findings/grounding.md](findings/grounding.md) · Open questions:
> [findings/open-questions.md](findings/open-questions.md)

## One-paragraph summary
Make the Woven fork of AFFiNE **publish its self-host server container image to
GitHub Container Registry under `aRustyDev`** — `ghcr.io/arustydev/affine:woven-<sha>`
(+ a moving `:woven` tag), **public** — on push to `woven/main` and on demand, so the
ds-cleaner k3s deployment (infra epic `infra-bt6g`) can pull it. Today the fork only
builds images **locally** (`scripts/woven-build-image.sh` → `woven/affine:<sha>`, no
registry; that is the `affine-yiz` *local-compose* CD track). Upstream's
`build-images.yml`/`release.yml` publish to `ghcr.io/toeverything/affine` but require
proprietary secrets (R2/Sentry/Perfsee/AFFINE_PRO) the fork does not hold. This plan
adds a **fork-local, rebase-safe** publish workflow (`woven-*` namespaced) that builds
the community self-host server image without those secrets and pushes it to the fork's
GHCR namespace.

## Documents
| Doc | What |
|---|---|
| [findings/grounding.md](findings/grounding.md) | Verified facts: upstream build pipeline, Dockerfile, required vs optional secrets, existing fork CD, GHCR mechanics |
| [findings/decision-log.md](findings/decision-log.md) | D1–D6 |
| [findings/open-questions.md](findings/open-questions.md) | OQ-0 (beads migration blocker) … |

## Prime-directive note (fork policy)
Per `scripts/woven-agent-bootstrap.md`: this is a hybrid fork. This work is **additive
infrastructure**, not a core patch — it is `woven-*` namespaced and rebase-safe against
weekly `canary` merges. It does **not** touch upstream `build-images.yml`/`release.yml`
(editing those would fork them and break rebases; see D2). It is fork-local (never
upstreamed) because it hardcodes the fork's registry + drops the proprietary build legs.

## Operator decisions baked in (see decision-log)
- **D1 — Public GHCR package** (mirrors the infra-side D2). No token handoff to the
  cluster; the cross-DB contract is simply "a public, pullable image exists".
- **D2 — New fork-local workflow, do NOT edit upstream `build-images.yml`.** Add
  `.github/workflows/woven-publish-image.yml`; derive the owner from
  `${{ github.repository_owner }}` (never hardcode `toeverything`). Rebase-safe.
- **D3 — Self-host *server* image only.** Build web + admin + server (+ server-native for
  the target arch); skip mobile/desktop. This is the single-container self-host image the
  ds-cleaner chart runs — not the multi-service cloud topology.
- **D4 — Build without proprietary secrets.** R2/Sentry/Perfsee are source-map/telemetry
  uploads (safe to omit → empty env). `AFFINE_PRO_*` gates the licensed native build →
  omit for a community/self-host build (spike A0 confirms what breaks).
- **D5 — Tagging: immutable `woven-<short-sha>` + moving `:woven`.** Cluster values pin the
  immutable ref; `:woven` is for humans. OCI label `org.opencontainers.image.source` →
  the fork repo so the package links to it.
- **D6 — Arch = the cluster's arch (expect amd64).** Confirm via infra OQ-3; drop
  `linux/arm/v7` and (probably) `arm64` to keep CI fast. Multi-arch is a later nicety.

## Phases (beads epic `affine-3ab`, tasks `.1`–`.4` = A0–A3)
- **A0 — Build spike.** Determine the minimal community self-host image build in CI:
  which upstream secrets are truly required vs safely-empty (R2/Sentry/Perfsee/AFFINE_PRO),
  target arch, and whether to *call* upstream's reusable `build-images.yml` (needs it
  parametrized on registry — a minimal, arguably-upstreamable edit) or **fork the build
  steps** into `woven-*`. Produce a runnable server image locally/in a scratch CI run.
- **A1 — Fork-local publish workflow.** `.github/workflows/woven-publish-image.yml`:
  builds web+admin+server(+server-native for arch) and pushes
  `ghcr.io/${owner}/affine:woven-<sha>` (+ `:woven`) via `.github/deployment/node/Dockerfile`
  (or the fork's `woven.Dockerfile`), on `push` to `woven/main` + `workflow_dispatch`.
  `packages: write`, `GITHUB_TOKEN`, `docker/login-action` to `ghcr.io`.
- **A2 — Package public + labels + tagging/retention.** Set the GHCR package visibility
  **public**; add OCI labels (`image.source`, `image.revision`, `image.version`); link the
  package to the repo; document the tag/retention policy. **This is the capability task**
  — carries label `export:affine-ghcr-image`; on close run `bd ship affine-ghcr-image`.
- **A3 — Consumption contract + reconcile with `affine-yiz`.** Write the immutable-ref
  contract the infra epic consumes; reconcile the CI image with the local-compose CD
  (`affine-yiz`) so a promoted image and a CI image are byte-comparable / interchangeable
  where it matters (or explicitly document why they differ).

## Cross-epic dependency (the one hard link)
This epic **provides** `affine-ghcr-image` (label `export:affine-ghcr-image` on A2 →
`bd ship affine-ghcr-image` on close). The infra epic `infra-bt6g` (+ `infra-bt6g.1`)
**depends on** `external:affine:affine-ghcr-image` and cannot cut over until it resolves
(a closed A2 with `provides:affine-ghcr-image`). Contract: **this epic publishes
`ghcr.io/arustydev/affine:woven-<sha>` (public); infra pins that exact ref.**

## Beads migration (RESOLVED 2026-07-13)
The `affine` Dolt DB was **schema v49**; bd wanted **v53**, and refused to auto-migrate a
*remote-backed* DB (migrating >1 clone independently forks the schema irrecoverably). This
Mac was confirmed the **designated migrator**: safety-export (52 issues) →
`BD_ALLOW_REMOTE_MIGRATE=1 bd migrate` (Dolt 1.0.5 → 1.1.0) → `bd dolt push` to publish the
migrated schema. Epic `affine-3ab` was then filed. See open-questions **OQ-0** for the
recorded commands.
