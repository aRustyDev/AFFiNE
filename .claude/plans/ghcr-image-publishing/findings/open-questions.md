# Open questions — ghcr-image-publishing

## OQ-0 — RESOLVED 2026-07-13: `affine` Dolt DB migrated v49 → v53; epic `affine-3ab` filed

This Mac was confirmed the designated migrator. Done: `bd export --all` (52 issues, safety)
→ `BD_ALLOW_REMOTE_MIGRATE=1 bd migrate` (1.0.5 → 1.1.0) → `bd dolt push`. Epic `affine-3ab`
(tasks `.1`–`.4`) then created; A2 (`affine-3ab.3`) carries `export:affine-ghcr-image`.
Historical detail (the guard's own instructions) below.

The `affine` DB refuses writes until migrated, and refuses to auto-migrate because it is
remote-backed (`git+ssh://git@github.com/aRustyDev/AFFiNE.git`). **Operator decision: is
THIS machine the sole/designated migrator?**

- If yes (designated migrator): back up first, then migrate + publish, then file the epic:
  ```
  cd /Users/asmith/repos/woven/forks/AFFiNE
  bd export --all -o .beads/backup-pre-v53-$(date +%Y%m%d).jsonl   # safety
  BD_ALLOW_REMOTE_MIGRATE=1 bd migrate
  bd dolt push        # publish the migrated schema (requires operator push authority)
  ```
- If another clone already migrated: `bd bootstrap` (re-clone) instead — WARNING: replaces
  the local DB; export/push unpushed issues first.

**After migration, file the epic + tasks (adjust wording as needed):**

```
cd /Users/asmith/repos/woven/forks/AFFiNE
EP=$(bd create "[epic] Publish Woven fork container images to ghcr.io/aRustyDev/AFFiNE (public) for k3s consumption" \
  -t epic -p 1 -l woven,cd,ghcr,fork-local --silent \
  -d "See .claude/plans/ghcr-image-publishing/PLAN.md")
A0=$(bd create "ghcr A0: build spike — minimal community self-host image w/o proprietary secrets; arch; reuse-vs-fork build" -t task -p 1 --parent "$EP" --silent)
A1=$(bd create "ghcr A1: fork-local woven-publish-image.yml — build+push ghcr.io/\${owner}/affine:woven-<sha> on push to woven/main + dispatch" -t task -p 1 --parent "$EP" --silent)
A2=$(bd create "ghcr A2: package public + OCI labels + tag/retention + link to repo" -t task -p 1 --parent "$EP" -l export:affine-ghcr-image --silent)
A3=$(bd create "ghcr A3: consumption contract + reconcile with affine-yiz local-compose CD" -t task -p 2 --parent "$EP" --silent)
bd dep add "$A1" "$A0"; bd dep add "$A2" "$A1"; bd dep add "$A3" "$A2"
# capability handoff (run when A2 closes): bd ship affine-ghcr-image
echo "epic=$EP A0=$A0 A1=$A1 A2=$A2 A3=$A3"
```

Then wire the infra side's `external_projects` so `external:affine:affine-ghcr-image`
resolves (infra plan OQ-2).

## OQ-1 — What actually breaks with the proprietary secrets empty? — RESOLVED 2026-07-13

**Nothing.** A0 rungs 1+2 built web/admin/mobile/server clean with R2/Sentry/Perfsee/Captcha
empty and `AFFINE_PRO_*` unset — no leg hard-failed, none needed gating/stubbing. See
decision-log "Spike results". (Original text below.)
A0 must prove the web/admin/server build succeeds with R2/Sentry/Perfsee/Captcha unset and
without `AFFINE_PRO_*`. If a leg hard-fails on a missing secret, decide: stub it, gate the
step behind `if: secrets.X != ''`, or provide a fork-owned equivalent.

## OQ-2 — Reuse upstream reusable workflow, or fork the build steps? — RESOLVED 2026-07-13

**Neither — reuse the fork's own `scripts/woven.Dockerfile`.** A single monolithic
from-source build replaces the 5-job matrix, needs no registry parametrization and no
`@toeverything` scope wiring, is already `woven-*`/rebase-safe, and fits a stock CI runner
(~24 min). See decision-log "Spike results". (Original text below.)
Calling `build-images.yml` needs it parametrized on registry owner (minimal edit, breaks
the "don't edit upstream" rule of D2 unless upstreamable). Forking the ~5 build jobs into
`woven-*` is self-contained but duplicates ~250 lines that drift from `canary`. A0 recommends.

## OQ-3 — Does `yarn workspaces focus @affine/server --production` resolve the

`@toeverything` npm scope in the fork with only `GITHUB_TOKEN`? (Private-package risk.)
**RESOLVED 2026-07-13: no token needed.** `.yarnrc.yml` targets public `registry.npmjs.org`
with no scope override; `yarn install --immutable` + `workspaces focus` resolved everything
with no npm auth in both A0 rungs.

## OQ-4 — Signing/provenance/SBOM.** Upstream sets `provenance: true`. Keep it (adds

attestation) or drop for speed? Cosign signing optional; the cluster pulls a public image
by tag (consider pinning by digest in `values-affine.yaml`).
