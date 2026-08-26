# Woven AFFiNE — CD runbook (fork-local)

Continuous-deploy tooling for the fork, targeting the **live `woven-local` stack**
(`~/repos/woven/infrastructure/helm-charts/local-dev/`), resolved **by identity**
(the container publishing `:3010`) so it survives compose-project renames.

All scripts live in `scripts/woven-*` and are bash-3.2 safe. The live target,
image ref, DB container, and named volumes are discovered at run time via
`scripts/woven-resolve-live.sh` — nothing is hardcoded to `woven-local`.

> Blast radius: `stage`, `backup`, `rehearsal`, `restore` are read-only or fully
> isolated. **`prod` and `rollback` edit live infra** (`<live>/.env`) and recreate
> the live `affine` service — both require typed confirmation.

## Pieces

| Script                                             | Role                                                                                         | Touches live?      |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------ |
| `woven-resolve-live.sh`                            | resolve live server/project/pg/image/volumes by identity                                     | read-only          |
| `woven-backup.sh`                                  | pg_dump + storage + config(+private.key) + manifest → `~/.affine/backups/<ts>/`              | read-only          |
| `woven-restore.sh` (+ `woven-restore.compose.yml`) | restore drill into an isolated stack (`:3011`)                                               | isolated           |
| `woven-migration-rehearsal.sh`                     | **.4 gate**: predeploy idempotency + destructive-scan + PREV-image backward-compat (`:3021`) | isolated           |
| `woven-build-image.sh` (+ `woven.Dockerfile`)      | build a local `woven/affine:<sha>` from source                                               | none               |
| `woven-staging.compose.yml` (+ `.env.example`)     | isolated staging stack, indexer ON, `:3020/:5442/:6389`                                      | isolated           |
| `woven-promote.sh stage\|prod\|rollback`           | the CD flow                                                                                  | prod/rollback only |
| `woven-ci-min.sh`                                  | pre-deploy code gate (typecheck/lint/codegen-drift/AVA)                                      | disposable DB      |

## 0. One-time setup (requires your approval — edits live infra)

1. **Add the `AFFINE_IMAGE` override** to `services/affine.yaml` so a fork image can
   be promoted (byte-identical behaviour when `AFFINE_IMAGE` is unset). Change the
   `image:` line on **both** `affine` and `affine-migration` (they must match):
   ```
   BEFORE: image: ghcr.io/toeverything/affine:stable@sha256:74baac63…
   AFTER : image: ${AFFINE_IMAGE:-ghcr.io/toeverything/affine:stable@sha256:74baac63…}
   ```
   `cp services/affine.yaml services/affine.yaml.bak.<ts>` first (it is git-tracked).
   Verify: `docker compose -f compose.yaml config | grep toeverything/affine` (still the
   pinned digest when `AFFINE_IMAGE` unset). `prod` refuses until this override exists.
   > `<live>/.env` is `just secrets`-generated; **re-apply `AFFINE_IMAGE` after any
   > `just secrets` run**. Keep `.env`/`.env.bak.*` at `chmod 600` (they hold DB creds).
2. **Commit the `scripts/woven-*` tooling** (or the build refuses: a dirty tree makes the
   sha tag lie about image contents). `WOVEN_ALLOW_DIRTY=1` builds a non-promotable
   `…-dirty` tag for experiments.
3. **First image build** (deferred, 10–30 min, ≥8 GB RAM): `scripts/woven-build-image.sh`.

## 1. STAGE — one command

```
scripts/woven-promote.sh stage                 # builds woven/affine:<sha>, stages it
scripts/woven-promote.sh stage --image REF      # stage a specific image (e.g. an upstream bump)
```

Does: pick candidate → **if it introduces migrations not in the live DB, run the `.4`
rehearsal gate and abort on failure** → back up live → seed an isolated staging stack
from the newest snapshot → run predeploy (indexer ON, prod parity) → boot → health-check
on `http://localhost:3020`. Inspect staging, then promote.
Fast dry validation (no source build): `stage --image <live-ref> --skip-backup --seed-from <backup-dir>`.

## 2. PROD — one command (typed confirmation)

```
scripts/woven-promote.sh prod                  # promotes the STAGED candidate
scripts/woven-promote.sh prod --dry-run         # prints the plan, writes nothing
```

Refuses unless the candidate was the last **staged** image. **Re-derives** the schema
signal from image-vs-live-DB (never trusts a flag) and requires a rehearsal token bound
to the image id for schema-changing releases. Takes a **mandatory fresh backup**, writes
a rollback marker, then (after you type `promote <tag> to prod`) flips `AFFINE_IMAGE` in
`<live>/.env`, recreates the live `affine` service (predeploy runs via its dependency),
and health-checks the **specific live container** (not host `:3010`).

## 3. ROLLBACK

```
scripts/woven-promote.sh rollback              # TIER 1: restore previous image only (no predeploy)
scripts/woven-promote.sh rollback --db          # TIER 2: also restore DB + blobs from the pre-promote backup
```

- **TIER 1** (additive / expand-only releases): recreate the server on the previous image
  with `--no-deps` (predeploy NOT re-run). New-table/column data becomes orphaned, not lost.
- **TIER 2** (contract/destructive change or corruption): typed `restore db` → **fresh
  safety backup of current live first** → DB restore (`--clean --if-exists` dump) → blobs
  merged into the live volume via a temp-then-`cp -a` swap. **Never `rm -rf`s the live
  config volume; `private.key` is left untouched.**
- ⚠ **Projection/dual-write releases** (e.g. `…backfill-permission-projection`,
  entitlement/quota projections): after an image-only rollback the old binary stops
  maintaining those projections → silent staleness. Prefer TIER 2 for these.

## Invariants & caveats

- Live ops always use `--project-directory <live> --env-file <live>/.env -p <project>`.
- Candidates are pinned by `woven/affine:<sha>` (never a moving tag). Local images have no
  registry digest — keep the previous image (it stays local as `LIVE_IMAGE_ID`) or
  `docker save` it; if the OrbStack image store is wiped, rebuild the rollback target from git.
- Staging runs indexer ON (manticore) for predeploy parity, but is **not** full functional
  parity (no Zitadel/OIDC, object storage, etc.). Green staging ≠ complete prod simulation.
- The `.4` gate certifies **backward-compat + no data loss**, not rollback safety for
  projection releases (see TIER 2).
- Markers (git-excluded): `.woven-rehearsed/<image-id>`, `.woven-staged-image`,
  `.woven-prod-rollback`, `.woven-deployed-id`.
