# Decision log — selfhost-quota-limits

Operator decisions taken 2026-08-31/2026-09-01 during design of bead `affine-vap`. The PLAN
states each decision; this file records the **alternatives that were considered and rejected**,
so a future reader does not re-litigate them.

## D1 — Configurable numbers, not a boolean bypass

Rejected: `woven.ignoreMemberLimit` (a boolean), as the bead originally proposed.

"Unlimited" has to become a concrete value somewhere: `seat_limit` is `i32` in Rust, is an int4
column, and feeds arithmetic in the native invite-abuse policy (`seat_limit * 2`). A boolean
just makes the magic number implicit instead of explicit.

## D2 — Patch TypeScript, not the Rust plan catalog

Rejected: bumping `member_limit: Some(10)` ⇒ `Some(100)` in `entitlement.rs` (the bead's stated
fallback).

The original argument against it — "requires a native rebuild" — is **wrong**, and was corrected
during design: `build-server-native` has no path filter and rebuilds the Rust module on every CI
run regardless. The real costs are:

- `entitlement.rs` carries upstream's own assertions on these values (`:584`, `:601`, `:688`), so
  the patch must also edit upstream's tests **in the same upstream-owned file** — a guaranteed
  conflict on every sync.
- It is not runtime-toggleable, so upstream behavior cannot be reproduced in a test.
- It hard-codes a new arbitrary ceiling rather than making the ceiling a decision.

## D3 — `-1` = inherit, `N >= 1` = floor, `0` rejected

Rejected: `0` = unlimited (the operator's initial preference, withdrawn on the grounds that a
sentinel is not truly unlimited and a large `N` is honest about what it is).

Independently, `0` would have been actively dangerous: upstream already uses `0` to mean _no
seats_ (`state.ts:167` `quota.seatLimit ?? 0`), which drives `overcapacityMemberCount =
memberCount` and immediate readonly. A misread of the convention would have bricked a workspace.

Also rejected: defaulting each knob to upstream's plan value (10 / 100GB / 100MB). That would
duplicate catalog constants in the fork, where they would silently drift from the Rust source of
truth. `-1` = inherit makes "flag off ⇒ upstream behavior" provable with no duplication.

## D4 — Floor semantics via `max()`, never `min()`

A floor can only ever raise a limit. It is a no-op for a plan already above it, so it cannot
lower a licensed `selfhost_team` workspace, and it lifts an under-provisioned one. `min()` or
plain assignment would both risk silently reducing a licensed plan.

## D5 — Self-hosted only

Guarded on `env.selfhosted`. Cloud is untouched by construction rather than by convention, which
also means the knobs cannot become a cloud-side entitlement bypass if this code were ever
upstreamed or copied.

## D6 — Override the resolved quota object once

Rejected: patching `state.ts:167` alone (the bead's recon, and this design's own first draft).

That misses `state.ts:166`, where the readonly comparison reads `quota.storageQuota` directly
rather than through the persisted value. Overriding the `quota` object where it is chosen
(`:161`) covers the readonly check, `seatLimit`, and the persisted projection in one expression.

## D7 — Apply at both reconcile sites

User (`state.ts:84`) as well as workspace (`:161`). In Mode A the workspace borrows the owner's
quota, so patching only the workspace site would leave `getUserQuota` reporting a limit that
contradicts the workspace's effective one.

## D8 — Invite ceiling via deployment config, not code

Chosen: `auth.inviteQuotaShadowMode = true` in the fork's deploy config.

Rejected: **shipping it on by default in the fork** — silently lowers abuse protection for every
deployment of the image, and would need its own manifest consideration.

Rejected: **patching `plan_ceiling_7d` in Rust** — `invite_quota_config()` returns
`InviteQuotaConfig::default()` unconditionally (`runtime/config.rs:479`), guarded by an upstream
test named `invite_quota_policy_is_internal_not_app_configurable` (`:893`). Plumbing a flag
through means editing that test and overriding an explicit upstream design decision, for a second
NEVER-upstream core patch in the abuse subsystem.

Rejected: **relying on the invite-link path alone** (it bypasses the ceiling entirely) — correct
but a worse onboarding flow for large batches. Documented as the fallback if shadow mode is ever
turned back off.

Accepted cost: shadow mode disables _all_ invite-quota enforcement — spam, high-risk domains,
disposable-email cohorts — not just the seat-derived ceilings. Acceptable for an SSO-gated
private instance with `allowSignup: false`; must be re-examined if the instance ever accepts
public signup.

## D9 — Mode B (self-minted self-host Team license) is a separate bead

Considered and **not** rejected — the operator wants it built, but as its own unit of work. It is
a different kind of change: P-256 keypair generation, secret custody and backup, two build args
in the fork-owned Dockerfile/publish workflow, a minting CLI, and a per-workspace install
runbook. It also depends on these knobs, which are its safety net against the expiry cliff and
against an upstream format change (neither of which any CI can detect, since no file diverges).

Format research preserved in [mode-b-license-format.md](mode-b-license-format.md).

## D10 — Procurement ruled out

Buying a self-host Team license would deliver Mode B with zero patches, zero secrets and zero
format fragility, and was raised explicitly as the only route with no engineering downside.
The operator ruled it out: design constraints preclude the procurement option. Recorded so the
option is visibly considered rather than overlooked.

## Rejected wholesale: migrate to AFFiNE Cloud

Cloud `team` resolves `member_limit` from the Stripe subscription `quantity`, so the cap would
simply not exist, with no patching. Rejected because it collides with the constraint that created
this fork: the patch manifest's first entry exists so AFFiNE can reach `id.auth.woven`, an
internal **org-CA-signed** Zitadel issuer. OAuth provider configuration is server-side, so on
AFFiNE-hosted cloud the customer does not control it, and their infrastructure cannot reach an
internal issuer behind a private CA regardless. It would also surrender data residency and
release-cadence control, and moot the CD platform (`affine-4yo`) and migration-safety
(`affine-tc6`) work.

Not verified from the repo: AFFiNE's current commercial cloud SSO capabilities and pricing. If
cloud is ever reconsidered, that is a vendor question to put to AFFiNE directly.
