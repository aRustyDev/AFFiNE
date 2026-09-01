# Grounding — selfhost-quota-limits

Verified by reading the tree at HEAD `c6fc3b2dec` (upstream baseline `v0.27.4` /
`b4c8548c09`) on 2026-09-01. Line numbers are accurate at that commit and will drift; the
symbol names are the durable reference.

## 1. There is no existing configuration surface

`grep -i 'member_limit\|seat_limit'` across `src/base/config`, `src/core/config`, and `docs`
returns **nothing**. No env var, no `AppConfig` entry, no documented or undocumented knob.

The caps are compile-time constants in the Rust plan catalog,
`packages/backend/native/src/entitlement.rs:445`:

```rust
"selfhost_free" => PlanQuota {
  blob_limit: 100 * ONE_MB,
  storage_quota: 100 * ONE_GB,
  member_limit: Some(10),
  ...
}
```

Every self-hosted workspace lands on that plan by construction (`entitlement.rs:128`):
selfhosted + no `signedPayload` ⇒ `selfhost_free`, and `:134` rejects anything else —
_"selfhosted commercial entitlements require signedPayload"_. The only upstream-supported
escape is a signature-verified `selfhostedteam` license whose `quantity` becomes
`member_limit: Some(seats)` (`:439`), capped at `MAX_SEAT_QUANTITY = 100_000` (`:29`).

This is deliberate, signature-enforced monetization — which also explains why no flag exists:
a config knob would be a bypass of the license check.

## 2. The projection is the single choke point

`entitlement.rs` `quota()` (`:468`) maps `member_limit` ⇒ `seat_limit`. TypeScript
`EntitlementService.resolveBestEntitlement` returns it, and `QuotaStateService` persists it to
`effective_workspace_quota_states`. **Every** enforcement point reads the persisted projection:

| #   | Enforcement point                                                                        | Mechanism                                                                                                                           |
| --- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `quota/service.ts:111` `tryCheckSeat` ← `member.ts:790` `acceptInvitationByEmail`        | `NoMoreSeat`                                                                                                                        |
| 2   | `member.ts:332` `inviteMembers` batch                                                    | `NoMoreSeat`                                                                                                                        |
| 3   | `member.ts:536` `approveMember` (invite-link review)                                     | `NoMoreSeat`                                                                                                                        |
| 4   | `quota/state.ts:168` `overcapacityMemberCount`                                           | `member_overflow` ⇒ readonly ⇒ `permission/policy.ts:63`, and `assertWorkspaceAcceptsMemberChange` then blocks _all_ member changes |
| 5   | `blob.ts:185-191`                                                                        | `BlobQuotaExceeded` (per-file) / `StorageQuotaExceeded` (total)                                                                     |
| 6   | frontend `desktop/dialogs/setting/workspace-setting/members/cloud-members-panel.tsx:209` | client-side block + upgrade modal, before the server is called                                                                      |

1–3 all read `state.seatLimit` via `getWorkspaceSeatQuota` (`quota/service.ts:104`). 6 reads it
verbatim from the realtime snapshot (`frontend/core/src/modules/quota/entities/quota.ts:72`),
so **no frontend patch is needed** if the projection changes.

Note the readonly comparison reads `quota.storageQuota` directly at `state.ts:166`, separately
from the persisted value at `:183`. Patching individual lines misses one; overriding the
resolved `quota` object at `:161` covers both.

`workspaces/abuse.ts:249` also reads `getWorkspaceSeatQuota`, but **only for log fields** — not
enforcement.

## 3. Accounting modes

Two, selected by `hasStandaloneWorkspaceQuota(plan)` (`state.ts:370`).

|                                   | **Mode A — delegated to owner**                                                                                                                                                            | **Mode B — standalone**                                                                                                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Plans                             | `free`, `pro`, `lifetime_pro`, `ai`, **`selfhost_free`**                                                                                                                                   | `team`, `selfhost_team`                                                                                                                                                        |
| Limit source                      | the **owner's user entitlement** (`state.ts:161` `quota = ownerEntitlement?.quota ?? resolved.quota`)                                                                                      | license/subscription `quantity`                                                                                                                                                |
| Seat enforcement                  | hard reject                                                                                                                                                                                | seat _allocation_: `member.ts:329` guards `if (!isTeam)`, so team invites never throw; members enter `AllocatingSeat` and `allocateAvailableTeamSeats` promotes as many as fit |
| Role management                   | **none** — `member.ts:589-591` throws `ActionForbiddenOnNonTeamWorkspace` for any change other than ownership transfer. `WorkspaceRole.Admin` (`models/common/role.ts:17`) is unassignable | full External / Collaborator / Admin / Owner                                                                                                                                   |
| Search honors per-doc permissions | **no** — `plugins/indexer/resolver.ts:158` `#readableDocIdsForSearch` returns `null` ⇒ `docIds: undefined` ⇒ search spans every doc in the workspace                                       | restricted to readable doc ids                                                                                                                                                 |
| Ownership-transfer fallback role  | Collaborator                                                                                                                                                                               | Admin (`models/workspace-user.ts:76`)                                                                                                                                          |
| Doc analytics window              | 7 days (`NON_TEAM_ANALYTICS_WINDOW_DAYS`, `models/workspace-analytics.ts:18`)                                                                                                              | up to 90 days (`:767`)                                                                                                                                                         |
| Doc last-accessed members         | last 7 days only (`:860`)                                                                                                                                                                  | unrestricted                                                                                                                                                                   |
| Storage quota                     | borrows the owner's pool                                                                                                                                                                   | standalone `quantity*20GB + 100GB` (`entitlement.rs:429`)                                                                                                                      |
| Members panel header              | `Members (n/limit)`                                                                                                                                                                        | `Members (n)` — no denominator (`cloud-members-panel.tsx:283`)                                                                                                                 |
| Account deletion                  | allowed                                                                                                                                                                                    | blocked while owning a team workspace (`models/user.ts:293`)                                                                                                                   |

Mode is derived from `state.plan` (`workspaces/service.ts:106`), which this plan does not
touch — so `selfhost_free` stays in Mode A and its hard-reject branch simply never trips. No
mode switch.

On the per-doc-permission row: `grantDocUserRoles` (`workspaces/resolvers/doc.ts:715`) has **no**
plan gate, so per-doc roles _can_ be set on a `selfhost_free` workspace — they just do not
constrain search hits. Scope of the exposure is search results (titles, snippets); opening a doc
is authorized separately.

## 4. Storage is metered against your own disk

Default provider is `fs` (`core/storage/config.ts:31,42`) — local disk, or S3/R2 if configured.
Nothing touches AFFiNE-hosted storage. The quota is enforced anyway: `blob.ts:185-191` throws,
and `state.ts:169-171` sets `storage_overflow` ⇒ the workspace goes **readonly**.

In Mode A it is tighter than "100GB per workspace": `getOwnerStorageUsage` (`state.ts:277`) sums
usage across **every non-team workspace the owner owns** and charges the total to the owner's
single 100GB. 40 people in one `selfhost_free` workspace share one pool tied to whoever owns it
(~2.5GB/person), and that owner's personal workspaces consume the same pool.

So "100GB + 20GB/seat" is a quota _formula_, not a storage service.

## 5. The seat limit caps workspace membership, not logins

No instance-wide user cap exists — no `userLimit`, `maxUsers`, `totalUsers`, or equivalent
anywhere in `packages/backend/server/src` or `packages/backend/native/src`.

`memberCount = active members + invitations not awaiting review` (`state.ts:312`). Invite-link
requests in `waiting_review` do **not** consume a seat; pending email invitations do.

Any number of OIDC users can authenticate and be provisioned. Each gets their own
`selfhost_free` user entitlement — see §6, they can never get anything else.

`createWorkspace` (`workspaces/resolvers/workspace.ts:208` ⇒ `models/workspace.ts:93`) has no
plan gate, no quota check and no count limit: any authenticated user can create workspaces
freely, and each new one is its own Mode A `selfhost_free` workspace.

## 6. On self-hosted, no other entitlement path can move the numbers

All three sources checked:

- **`cloud_subscription`** — Stripe; not reachable self-hosted.
- **`admin_grant`** — dead on self-hosted. `validSelfhostEntitlementWhere()`
  (`entitlement/service.ts:664`) hard-filters _every_ entitlement query to
  `source:'selfhost_license', plan:'selfhost_team', targetType:'workspace'` when
  `env.selfhosted`. Admin grants never match. Subtly, that filter is ANDed onto **user**-target
  queries too, where it also demands `targetType:'workspace'` — contradicting the query's own
  `targetType:'user'`. So **user entitlements match zero rows on any self-hosted deployment**,
  and every self-hosted user resolves to `builtinFree('user')` ⇒ `selfhost_free`. Since that is
  Mode A, the owner-side 10 _is_ the workspace's limit.
- **`selfhost_license` with `signedPayload: null`** — looked like a real bypass and is not.
  `validEntitlementWhereForTarget` (`:651`) explicitly admits such rows, and `:501` remaps them
  to `deploymentType: 'cloud'`, which skips the Rust "requires signedPayload" guard and would
  return `member_limit: Some(quantity)` from a plain DB insert. But `getBestEntitlement`
  (`:121-130`) refuses to return an unsigned row without `verifyRemoteSelfhostLicense` ⇒
  `checkLicenseHealth` against AFFiNE's API, and the offline fallback (`:780`) only serves from a
  10-minute in-memory cache that a _prior successful_ remote check must have populated. Cold
  start without internet ⇒ `null`. Fail-closed.

## 7. The independent rolling invite ceiling

`native/src/runtime/backend_runtime/rolling_quota/workspace_invite_policy.rs`, reading
`seat_limit` from the same DB projection (`workspace_invite.rs:96`).

For `selfhost_free`, `plan_ceiling_7d` (`:81`) matches none of enterprise/team/trial/pro and
falls to the `else` branch ⇒ **10**, then `.min(seat_limit * 2)`. So **raising the seat limit
does not lift it**: ~10 invites per rolling 7 days per owner subject, plus `per_week = 10` per
actor.

It guards only `inviteMembers` (`member.ts:297`). The invite-link ⇒ `approveMember` path does
**not** call it, so link-based onboarding bypasses it entirely.

Rejection is a throw: `throw this.mapDecision(decision)` (`abuse.ts:351`).
`auth.inviteQuotaShadowMode` returns before reaching it (`abuse.ts:292`) and `member.ts` never
inspects the returned decision — so the flag **fully neutralizes** the ceiling, at the cost of
disabling all invite-quota enforcement.

Making it configurable in Rust instead is fighting upstream on purpose:
`invite_quota_config()` returns `InviteQuotaConfig::default()` unconditionally
(`runtime/config.rs:479`), guarded by a test named
`invite_quota_policy_is_internal_not_app_configurable` (`:893`).

## 8. Mechanics for the implementation

- **Config idiom** — `defineModuleConfig(<module>, {…})` in `<module>/config.ts`, loaded by
  `import './config';` at line 1 of `<module>/index.ts` (`core/version/config.ts` +
  `core/version/index.ts:1`). `env` accepts `string | [string, EnvConfigType]`. No snapshot test
  enumerates config keys, so adding one is cheap.
- **`QuotaStateService` does not inject `Config`** (`state.ts:38`) — the patch adds one
  constructor param.
- **`seat_limit` is int4** — `Int @db.Integer` (`schema.prisma:278`), and the native policy reads
  it as `i32`. `storage_quota` / `blob_limit` are `BigInt @db.BigInt` (`:281-282`).
- **Test harness** — `createTestingModule` + `module.get(ConfigFactory).override({…})`
  (`__tests__/utils/testing-module.ts:126`). `state.spec.ts:290` already sets
  `globalThis.env.DEPLOYMENT_TYPE = 'selfhosted'` and asserts `memberLimit === 10` for this exact
  plan — reuse the pattern, and leave that spec untouched as the default-behavior guard.
- **Native rebuild is not a differentiator** — `build-server-native`
  (`.github/workflows/build-test.yml:801`) has no path filter and no `if:`; the Rust module is
  rebuilt on every CI run regardless.
