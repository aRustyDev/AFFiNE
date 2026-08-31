# AGENTS.md — Woven fork of AFFiNE

**Read `scripts/woven-agent-bootstrap.md` first.** It is the canonical, tracked
agent bootstrap: toolchain, the disposable dev/test stack + safety, the
pre-deploy gate (`scripts/woven-ci-min.sh`), fork policy (additive vs
fork-local; the member-limit removal is **never** upstreamed), the seed fixture,
and the beads task workflow.

One safety rule that must not be missed: **server tests `TRUNCATE` the database.
Only ever point `DATABASE_URL` at the disposable stack (`localhost:5432`), never
at any database you care about.**

Deployment/CD is **not in this repo**. Merging to `woven/main` publishes
`ghcr.io/arustydev/affine:woven-<sha>` via `.github/workflows/woven-publish-image.yml`;
the `infrastructure` repo (`products/affine/kube`) re-pins that image **digest**
and applies. There is no deploy step to run from here — see
`scripts/woven-agent-bootstrap.md` §7.

> Note: the repo ignores root-level `*.md` (`.gitignore` `/*.md`), so this file
> is present in the working tree (auto-discovered by agent tooling) but not
> tracked. The durable copy is `scripts/woven-agent-bootstrap.md`. To make this
> pointer survive fresh clones too: `git add -f AGENTS.md`.
