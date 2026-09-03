# Mode B research — self-host Team license wire format and install path

Produced during design of `affine-vap`; **owned by the Mode B bead**, not by this plan. Verified
against HEAD `c6fc3b2dec` on 2026-09-01.

> **FORK-LOCAL.** This describes replacing the license trust root in a build the fork owns. It is
> **not** forging AFFiNE's signature — that would require their private key. The distinction
> matters and should stay in any document that reuses this research.

## Why this route needs no upstream-owned file change

The trust root is a **compile-time** constant, and the fork controls its own build:

- `packages/backend/native/src/lib.rs:62,65`
  ```rust
  pub const AFFINE_PRO_PUBLIC_KEY: Option<&'static str> = std::option_env!("AFFINE_PRO_PUBLIC_KEY");
  pub const AFFINE_PRO_LICENSE_AES_KEY: Option<&'static str> = std::option_env!("AFFINE_PRO_LICENSE_AES_KEY");
  ```
- Re-exported to TS via `server/src/native.ts:355-357`, consumed by
  `base/helpers/crypto.ts:309,323`. The `process.env` fallback there is gated on `!env.prod`, so
  in a production image only the compile-time value counts.
- Upstream's `.github/workflows/build-images.yml:145-146` feeds them from repo secrets.
- The fork's `woven-publish-image.yml` sets **neither** — its header comment says so explicitly —
  so today both are null and license verification is simply unavailable.

Setting them to a fork-owned keypair in the fork-owned Dockerfile/workflow is therefore purely
**ADDITIVE**: zero upstream-owned files, zero patch-manifest rows.

## Wire format

`resolve_selfhost_license` ⇒ `decrypt_license` (`entitlement.rs:263`) ⇒ `verify_license` (`:304`).

```
byte layout of the license file (the `signedPayload` bytes):
  [0]        iv_len   — must be exactly 12
  [1]        tag_len  — must be exactly 12
  [2..14]    iv       (12 bytes)
  [14..26]   GCM tag  (12 bytes — TRUNCATED, the crate alias is Aes256Gcm12)
  [26..]     ciphertext

cipher : AES-256-GCM, 12-byte authentication tag
key    : hex-decoded if the string is 64 hex chars and decodes to 32 bytes,
         otherwise sha256(string).  The server passes
         `AFFiNEProLicenseAESKey.toString('hex')`, where that buffer is
         sha256(AFFINE_PRO_LICENSE_AES_KEY) — i.e. effectively sha256(secret).

plaintext (JSON, serde camelCase):
  { "payload": "<json string>", "signature": "<hex DER>" }

signature : P-256 ECDSA (the `p256` crate), DER-encoded, verified with an SPKI PEM
            public key.  The signed message is  iv || payload_string_bytes
            — the IV is part of the signed message, binding signature to nonce.

payload (the inner JSON string, serde camelCase):
  { "expiresAt": <rfc3339>, "issuedAt": <rfc3339>, "entity": <non-empty>,
    "issuer": <non-empty>,
    "data": { "id": ..., "workspaceId": <uuid>, "plan": "selfhostedteam",
              "recurring": ..., "quantity": <1..=100000>, "endAt": <rfc3339> } }
```

Validation rules worth knowing before minting:

- `plan` inside `data` must be exactly `"selfhostedteam"` (`:187`) — note: **not**
  `selfhost_team`, which is the resolved plan name.
- `workspaceId` must match the target workspace or you get `workspace_mismatch` (`:190-196`) — a
  license binds to **one** workspace.
- `issuedAt`, `entity`, `issuer` must all be non-empty (`:200`).
- `quantity` in `1..=MAX_SEAT_QUANTITY` where `MAX_SEAT_QUANTITY = 100_000` (`:29`, `:255`).
- Effective expiry is `min(payload.expiresAt, data.endAt)` (`:213`). Past it the entitlement
  resolves as `expired` and the workspace falls back to `selfhost_free`.
- `deploymentType` must be `selfhosted` and `targetType` `workspace`, else
  `"signedPayload is only supported for selfhosted workspace entitlements"` (`:121`).

There is a working keypair in upstream's own test fixtures (`entitlement.rs:501-505`,
`TEST_PUBLIC_KEY` / `TEST_LICENSE_AES_KEY = "TEST_LICENSE_AES_KEY"`) — useful for validating a
minting script against the real verifier before generating production keys.

## Install path — fully offline

`installLicense` GraphQL mutation (`plugins/license/resolver.ts:151`), a `GraphQLUpload` gated on
`Workspace.Payment.Manage`, ⇒ `LicenseService.installLicense` (`service.ts:109`) ⇒
`EntitlementService.upsertFromSelfhostLicense` (`entitlement/service.ts:290`).

It sets `validateKey: ''` and stores the bytes as `signedPayload`. `getBestEntitlement`
short-circuits on `signedPayload` being present (`entitlement/service.ts:122`) and **never** calls
`checkLicenseHealth`. No network dependency at resolve time.

Contrast the unsigned path (§6 of grounding.md), which _is_ gated on reaching AFFiNE's API and
fails closed offline.

There is also an admin-only `previewLicense` mutation (`resolver.ts:175`) — useful for verifying a
minted file before installing it.

## What Mode B unlocks (and what it costs)

Unlocks, per grounding.md § _Accounting modes_: Admin roles, doc-permission-filtered search,
standalone per-workspace storage (`quantity*20GB + 100GB`) that stops counting against the
owner's personal pool, 90-day doc analytics, seat-allocation invites, and a members panel with no
denominator. It also raises the rolling invite ceiling from 10/7d to `min(30, seats*2)`, because
`plan_ceiling_7d` is plan-name-driven — still not unlimited, so D8's shadow mode is needed either
way.

Costs to design for in the Mode B bead:

1. **Per-workspace key ceremony.** One minted, hand-uploaded file per workspace, because of the
   `workspace_mismatch` binding. Not a config value.
2. **Expiry cliff.** Past the effective expiry the workspace drops to `selfhost_free` and — absent
   the `affine-vap` knobs — goes instantly over capacity and **readonly**. The knobs turn this
   into feature degradation instead of write loss. This is why Mode B depends on `affine-vap`.
3. **Secret custody.** A P-256 private key and an AES secret to hold and back up. The public half
   is baked into the image, so rotation means rebuild **and** re-mint every license.
4. **No CI can detect upstream breaking the format.** Any change to the payload schema, the
   truncated-tag choice, or the signing-message construction silently invalidates every license,
   and the patch-manifest guard sees nothing because no file diverges. Mitigation: a fork-owned
   test that mints a license with a fixture keypair and asserts the real `resolveEntitlementV1`
   accepts it — that _would_ fail on an upstream format change.
5. **The instance reports itself as a licensed paid tier.** Self-host Team is AFFiNE's commercial
   offering. Legitimate to do in a fork's own AGPL build with its own keypair, but a deliberate
   decision, not a side effect. Procurement was raised and ruled out on design constraints (D10).

Smaller than first assumed: **team billing UI is not a problem on self-host.** `showBilling` is
`!isSelfhosted && isTeam && isOwner` (`workspace-setting/index.tsx:81`), so the billing pane never
renders self-hosted. The License pane (`license/self-host-team-card.tsx`) shows seats and a
Deactivate action. Note `installLicense` sets `variant: Onetime`, so the card's `isOneTimePurchase`
branch displays `memberCount/memberLimit` rather than `license.quantity`.
