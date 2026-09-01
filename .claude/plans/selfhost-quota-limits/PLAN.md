# PLAN — selfhost-quota-limits (configurable self-host member / storage / blob quotas)

> **FORK-LOCAL CORE PATCH. MUST NEVER appear in an upstream-directed PR.** Per `affine-cm9`
> (fork strategy) and `scripts/woven-agent-bootstrap.md` §0, which names the member/seat-limit
> removal (`affine-vap`) as the fork's canonical never-upstream patch.
> Status: **DESIGN APPROVED — grounded 2026-09-01 against HEAD `c6fc3b2dec`. Not yet implemented.**
> Beads: `affine-vap` (this plan). Mode B — a self-minted self-host Team license — is split
> out as its own bead depending on `affine-vap`; its research is preserved here in
> [findings/mode-b-license-format.md](findings/mode-b-license-format.md).
> Grounding: [findings/grounding.md](findings/grounding.md) ·
> Decisions: [findings/decision-log.md](findings/decision-log.md)

## One-paragraph summary

Make the three self-host quotas that upstream hardwires into the Rust plan catalog
**configurable at runtime, defaulting to byte-identical upstream behavior**: the workspace
member cap (10), the total storage quota (100GB), and the per-file blob limit (100MB). All
three originate in `plan_catalog("selfhost_free", …)` in
`packages/backend/native/src/entitlement.rs` and reach every enforcement point through one
projection — `seatLimit` / `storageQuota` / `blobLimit` on `effective_workspace_quota_states`,
written by `QuotaStateService`. A single fork-owned helper applied at the two
`reconcile*QuotaStateNow` sites therefore covers all enforcement sites, the readonly
computation, and the frontend, in **one upstream-owned file**. There is no existing
configuration surface for any of these — no env var, no `AppConfig` entry, nothing in docs —
and the only upstream-supported way to raise them is a signature-verified self-host Team
license.

## Documents

| Doc                                                                    | What                                                                                            |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [findings/grounding.md](findings/grounding.md)                         | Verified facts with `file:line`: where the caps live, every enforcement point, accounting modes |
| [findings/decision-log.md](findings/decision-log.md)                   | D1–D9                                                                                           |
| [findings/mode-b-license-format.md](findings/mode-b-license-format.md) | Reverse-engineered self-host license wire format + install path, for the Mode B bead            |

## Prime-directive note (fork policy)

This is the fork's **second** and most consequential FORK-LOCAL CORE PATCH, in core quota — a
file upstream touches routinely. The failure mode is silent: a future upstream merge cleanly
reverts it, no test fails (upstream's tests assert the limits _are_ enforced), and the
regression surfaces in production as a member cap and a readonly workspace. Two mitigations
are mandatory and part of this plan, not optional follow-ups:

1. A `scripts/woven-patch-manifest.md` row for the one patched file, enforced by
   `scripts/woven-manifest-guard.sh` on every PR into `woven/main` (bead `affine-hn1.2`,
   closed). Run the guard locally before pushing; with no `--head` it also checks uncommitted
   work.
2. A `// FORK(woven):` marker on every changed line, so rebases and the eventual outbound-leak
   guard (`affine-hn1.4`, not yet built) can find them.

`gh pr create` in this repo defaults to the **parent** repo (`toeverything/AFFiNE`). Target the
fork explicitly. The `affine-hn1.2` PR only failed to open against upstream by naming
coincidence.

## Operator decisions baked in

- **D1 — Configurable numbers, not a boolean bypass.** A `woven.ignoreMemberLimit`-style flag
  would have to materialize "unlimited" as a sentinel in fields that are `i32`/`i64` in Rust and
  feed arithmetic in the native invite-abuse policy — an implicit magic number either way.
- **D2 — Patch TypeScript, not the Rust plan catalog.** `entitlement.rs` carries upstream's own
  assertions on these values (`:584`, `:601`, `:688`); editing the catalog means editing
  upstream's tests in the same upstream-owned file — a guaranteed conflict every sync — and
  gives up the ability to test both behaviors. The _rebuild_ cost is zero either way:
  `build-server-native` (`.github/workflows/build-test.yml:801`) has no path filter and runs on
  every CI run regardless.
- **D3 — `-1` = inherit, `N >= 1` = floor. No `0`.** `0` is **rejected at validation**. Upstream
  already uses `0` to mean _no seats_ (`state.ts:167` `quota.seatLimit ?? 0`, which drives
  `overcapacityMemberCount = memberCount` and instant readonly), so accepting `0` as "unlimited"
  would have been a live footgun. Practically: set `1000`, raise it when needed.
- **D4 — `max(resolved, configured)`, never `min`.** The knob is a **floor**. Default `-1`
  inherits the plan value untouched, so "flag off ⇒ upstream behavior" is provable without the
  fork duplicating any catalog constant (which would silently drift from Rust). A floor also
  lifts an under-provisioned license and can never _lower_ a licensed plan.
- **D5 — Self-hosted only.** All three knobs are inert unless `env.selfhosted`, so cloud
  behavior is untouched by construction.
- **D6 — Override the resolved `quota` object once, not the individual consumers.** The readonly
  comparison reads `quota.storageQuota` directly (`state.ts:166`), separately from the persisted
  value (`state.ts:183`), so line-by-line patching misses one. Overriding `quota` where it is
  chosen (`state.ts:161`) covers the readonly check, `seatLimit`, and the persisted projection in
  a single expression.
- **D7 — Apply at both reconcile sites.** User (`state.ts:84`) and workspace (`state.ts:161`). In
  Mode A the workspace borrows the owner's quota, so skipping the user site would leave the
  owner's displayed quota contradicting the workspace's effective one.
- **D8 — The rolling invite ceiling is handled by deployment config, not code.** Independent of
  the seat cap, a `selfhost_free` owner is capped at ~10 invites per rolling 7 days.
  `auth.inviteQuotaShadowMode = true` fully neutralizes it — verified: rejection happens via
  `throw this.mapDecision(decision)` (`abuse.ts:351`), shadow mode returns before reaching it
  (`abuse.ts:292`), and `member.ts` never inspects the returned decision. Set it in the fork's
  **deploy config**, not as a code default: zero files here, reversible per environment. Cost: it
  disables _all_ invite-quota enforcement, not just the seat-derived ceilings. The alternative —
  patching the ceiling in Rust — is worse: `invite_quota_config()` returns
  `InviteQuotaConfig::default()` unconditionally (`runtime/config.rs:479`), guarded by an upstream
  test named `invite_quota_policy_is_internal_not_app_configurable` (`:893`).
- **D9 — Mode B is a separate bead.** Team mode is genuinely different work (keypair, secret
  custody, two build args, a minting CLI, a per-workspace install runbook) with different risks,
  and it needs these knobs landed first — they are its safety net (see _Interaction with Mode B_).

## Design

### The knobs (new fork-owned file)

`packages/backend/server/src/core/quota/woven-config.ts` — fork-namespaced filename so a future
upstream `core/quota/config.ts` cannot collide by path.

| Config key                   | Env                            | Default | Meaning                          |
| ---------------------------- | ------------------------------ | ------- | -------------------------------- |
| `woven.selfhostSeatLimit`    | `WOVEN_SELFHOST_SEAT_LIMIT`    | `-1`    | inherit \| `N >= 1` member floor |
| `woven.selfhostStorageQuota` | `WOVEN_SELFHOST_STORAGE_QUOTA` | `-1`    | inherit \| `N >= 1` bytes floor  |
| `woven.selfhostBlobLimit`    | `WOVEN_SELFHOST_BLOB_LIMIT`    | `-1`    | inherit \| `N >= 1` bytes floor  |

Validation: `z.number().int().min(-1)` plus a refinement rejecting `0` with a message pointing
at `-1`. `selfhostSeatLimit` additionally `.max(2147483647)` — `seat_limit` is
`Int @db.Integer` (int4) in `schema.prisma:278`, and the native invite policy reads it as `i32`.

The module registers via `defineModuleConfig('woven', …)` following the established idiom
(`core/version/config.ts` is the reference), and exports the pure override helper so the logic
and its unit tests are fork-owned and rebase-safe. Only the _call sites_ are upstream-owned.

```ts
export function applyWovenSelfhostQuota(quota: Quota, woven: WovenConfig): Quota;
```

Semantics per field: `configured === -1` ⇒ return the resolved value unchanged; otherwise
`max(resolved ?? 0, configured)`. The `?? 0` matters for `seatLimit`, which is `Option<i32>` on
the Rust side and whose `null` currently means _no seats_. Numeric fields are returned as
`number` to keep the native-derived `Quota` type intact; comparisons are exact for byte counts
below 2^53 (~9 PB), which is not a practical constraint.

### The patch (one upstream-owned file)

`packages/backend/server/src/core/quota/state.ts`, four small regions, each marked
`// FORK(woven): configurable self-host quotas (bead affine-vap)`:

1. side-effect + helper import of `./woven-config`
2. `Config` added to the constructor — `QuotaStateService` does not currently inject it
   (`state.ts:38`)
3. `state.ts:84` — wrap `resolved.quota` for the user projection
4. `state.ts:161` — wrap the chosen workspace quota (`ownerEntitlement?.quota ?? resolved.quota`)

Everything downstream follows with no further edits:

| Consumer                                                           | Reads                                | Effect of the floor                     |
| ------------------------------------------------------------------ | ------------------------------------ | --------------------------------------- |
| `state.ts:168` `overcapacityMemberCount`                           | `seatLimit`                          | 0 ⇒ no `member_overflow` ⇒ not readonly |
| `service.ts:104` `getWorkspaceSeatQuota` ⇒ `tryCheckSeat` (`:111`) | persisted `seatLimit`                | all seat checks pass                    |
| `member.ts:332`, `:536`, `:790`                                    | same                                 | `NoMoreSeat` never thrown               |
| `state.ts:166` readonly comparison                                 | `storageQuota`                       | no `storage_overflow`                   |
| `blob.ts:185-191` upload checks                                    | persisted `storageQuota`/`blobLimit` | uploads accepted                        |
| frontend `modules/quota/entities/quota.ts:72` via realtime snapshot | `state.seatLimit`                    | members header + client invite gate lift |

The frontend needs **no patch**: it derives `memberLimit` verbatim from `state.seatLimit`.

## Phases (bead `affine-vap`)

- **T1 — Config module + pure helper.** `core/quota/woven-config.ts` plus unit tests requiring no
  DB: `-1` inherits, `N` floors, `N` below the plan value is a no-op, `0` is rejected,
  `seatLimit: null` + a floor yields the floor, non-selfhosted is inert.
- **T2 — The seam.** The four regions in `state.ts` with `// FORK(woven):` markers.
- **T3 — Integration spec.** `core/quota/__tests__/woven-selfhost-quota.spec.ts`, fork-owned,
  reusing the harness that `state.spec.ts:290` already uses for this exact plan
  (`globalThis.env.DEPLOYMENT_TYPE = 'selfhosted'` + `module.get(ConfigFactory).override(…)`).
- **T4 — Fork hygiene.** Manifest row for `state.ts` (**FORK-LOCAL CORE PATCH**, delete-when:
  upstream ships configurable self-host quotas); `scripts/woven-manifest-guard.sh` clean; PR
  targeted at the fork explicitly.
- **T5 — Deployment.** Record `auth.inviteQuotaShadowMode = true` and the three knob values in
  the fork's deploy config, with D8's trade-off noted where operators will read it.

## Verification (maps to the bead's acceptance criteria)

| Check                                                                                                                                                                                   | AC  |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- |
| Seat floor set: inviting/accepting an 11th member succeeds, no `NoMoreSeat` / `MemberQuotaExceeded`                                                                                      | 1   |
| With >10 members: `overcapacityMemberCount === 0`, `readonlyReasons` excludes `member_overflow`                                                                                          | 2   |
| Defaults (`-1`): limits still enforced — **and** upstream's own `memberLimit === 10` assertions at `state.spec.ts:309,312` keep passing untouched, which is the real regression guard     | 3   |
| Every changed line carries `// FORK(woven):`; manifest row exists; guard clean                                                                                                           | 4   |
| Change absent from any upstream-directed branch                                                                                                                                          | 5   |
| Storage floor: usage past the plan quota no longer sets `storage_overflow`; blob upload accepted                                                                                         | —   |
| `DEPLOYMENT_TYPE=cloud`: all three knobs inert                                                                                                                                          | —   |

## Interaction with Mode B (why the knobs come first)

If a minted license later expires or is invalidated, `getBestEntitlement`'s validity filter
excludes the row, resolution falls back to `builtinFree` ⇒ `selfhost_free` ⇒ seat limit 10 and
storage 100GB. A 40-member workspace would be instantly over capacity and **readonly**. With
these knobs in place the workspace degrades to _fewer features_ instead of _no write access_.
The same protection applies if an upstream merge ever changes the license wire format — which is
the main risk of the Mode B route, since no CI can detect it (no file diverges).

## Out of scope

- **`userMemberLimit(plan)`** — a second hardcoded `10` at `service.ts:220`, mirrored in the
  frontend at `modules/cloud/entities/user-quota.ts:60`. Informational only: it feeds the _user_
  quota display ("Pro users can invite up to 10"), not enforcement. Left alone.
- **The rolling invite ceiling** — deployment config per D8, not code.
- **Mode B / team mode** — its own bead. The knobs raise the numbers but do **not** unlock Admin
  roles, doc-permission-filtered search, or 90-day analytics; see
  [findings/grounding.md](findings/grounding.md) § _Accounting modes_.

## Risks

| Risk                                                                                                  | Mitigation                                                                                                                                                                                                       |
| ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Upstream merge silently reverts the patch; no test fails because upstream asserts enforcement          | Manifest row + enforced guard (`affine-hn1.2`); `// FORK(woven):` markers; the T3 spec fails loudly if the floor stops applying                                                                                    |
| The patch leaks into an upstream-directed PR                                                           | `affine-hn1.4` not yet built — until then, target PRs at the fork explicitly and never run bare `gh pr create`                                                                                                     |
| A large seat floor inflates the native invite-abuse ceilings, which read `seat_limit` from the DB row  | For `selfhost_free`, `plan_ceiling_7d` returns a plan-based `10` regardless of seat limit (`workspace_invite_policy.rs:81`), so the floor does not widen the abuse window; D8 handles the ceiling deliberately instead |
| `oxfmt` reformats these docs on the next hook-enabled commit                                           | Cosmetic; this worktree has no `node_modules`/`.husky/_`, so the hook could not run here                                                                                                                           |
