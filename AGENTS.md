# AGENTS.md — Woven fork of AFFiNE

**Read `scripts/woven-agent-bootstrap.md` first.** It is the canonical, tracked
agent bootstrap: toolchain, the disposable dev/test stack + safety, the
pre-deploy gate (`scripts/woven-ci-min.sh`), fork policy (additive vs
fork-local; the member-limit removal is **never** upstreamed), the seed fixture,
and the beads task workflow.

One safety rule that must not be missed: **server tests `TRUNCATE` the database.
Only ever point `DATABASE_URL` at the disposable stack (`localhost:5432`), never
at the live `woven-local` Postgres (`127.0.0.1:5433`).**

Deployment/CD lives in `scripts/woven-cd-runbook.md`; the validated gate design
and live-stack topology in `.beads/woven-cd-gate.md`.

> Note: the repo ignores root-level `*.md` (`.gitignore` `/*.md`), so this file
> is present in the working tree (auto-discovered by agent tooling) but not
> tracked. The durable copy is `scripts/woven-agent-bootstrap.md`. To make this
> pointer survive fresh clones too: `git add -f AGENTS.md`.
