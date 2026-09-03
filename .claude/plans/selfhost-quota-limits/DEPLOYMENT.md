# Self-host quota limits — deployment

Operator instructions for the `infrastructure` repository. Delivered by bead `affine-vap`
(PR aRustyDev/AFFiNE#5). Every path and behaviour below was verified against the code and against
upstream's own self-host assets at fork HEAD, not inferred.

**Nothing here changes behaviour until it is set.** The image ships with all three knobs at `-1`
(inherit), which is byte-identical to upstream. Deploying the image alone is safe and is a no-op.

---

## 1. What to set

Two separate mechanisms, because they are not both settable the same way.

### 1a. The three quota floors — environment variables

| Env var                        | Meaning                        | Suggested                |
| ------------------------------ | ------------------------------ | ------------------------ |
| `WOVEN_SELFHOST_SEAT_LIMIT`    | workspace member floor         | `1000`                   |
| `WOVEN_SELFHOST_STORAGE_QUOTA` | total storage floor, **bytes** | `966367641600` (900 GiB) |
| `WOVEN_SELFHOST_BLOB_LIMIT`    | per-file blob floor, **bytes** | `524288000` (500 MiB)    |

Semantics: `-1` inherits the plan value (the default). `N >= 1` is a **floor** — it raises a limit
but can never lower one, so it is safe against a future licensed plan. `0` is rejected.

Byte arithmetic, so you can pick your own without guessing:

```
100 GiB = 107374182400      500 GiB = 536870912000      900 GiB = 966367641600
100 MiB = 104857600         500 MiB = 524288000           1 GiB  = 1073741824
```

Without a floor, `selfhost_free` gives 10 members, 100 GiB total, 100 MiB per file.

### 1b. The invite rate ceiling — **not** an environment variable

`auth.inviteQuotaShadowMode` **has no env mapping.** Verified: its descriptor in
`core/auth/config.ts` has no `env:` key, so there is no `AFFINE_*` variable that sets it. Trying to
set one silently does nothing.

You need this. It is independent of the seat cap, and **raising the seat floor does not lift it**:
a `selfhost_free` workspace owner is capped at roughly **10 invites per rolling 7 days**, because
the native invite policy derives that ceiling from the plan name, not from the seat limit. Onboard
40 people by direct invite without it and you will stall in week one.

Two routes, both valid:

**Route A — admin settings panel.** Persisted to the database, validated on write, reloaded at
boot. Simplest, and it is the only _validated_ route for this key. Not declarative, so it will not
be captured in the infrastructure repo.

**Route B — `config.json`.** Declarative and GitOps-friendly. Mount a file at:

```
/root/.affine/config/config.json
```

That path is upstream's own convention — `.docker/selfhost/compose.yml` mounts `./config` to
`/root/.affine/config`. Contents:

```json
{
  "$schema": "https://github.com/toeverything/affine/releases/latest/download/config.schema.json",
  "auth": {
    "inviteQuotaShadowMode": true
  }
}
```

In Kubernetes that is a ConfigMap mounted at `/root/.affine/config`. Note the mount must not
clobber anything else the deployment already puts in that directory.

> **Two caveats on Route B.** `config.json` is applied **after** validation and is itself
> **not validated** — a malformed value is accepted silently rather than failing the boot. And it
> overrides env vars, so if you set a quota floor in both places, the JSON wins. Prefer env vars
> for the three numeric floors, and use `config.json` only for this boolean.

**What shadow mode costs.** It disables _all_ invite-quota enforcement — spam heuristics,
high-risk-domain rules, disposable-email cohort limits — not just the seat-derived ceiling. That is
a reasonable posture for an SSO-gated private instance with signup disabled. Re-examine it if the
instance ever accepts public signup.

---

## 2. Precedence, so you know what wins

Verified in `base/config/register.ts`:

1. the descriptor's built-in default (`-1`)
2. **env var** — if the key has an `env:` mapping and the variable is non-empty. **Validated here**
3. **`config.json`** — `<projectRoot>/config.json`, then `/root/.affine/config/config.json`. **Not validated**
4. **database app config** (admin panel) — validated on write, loaded at boot. Highest precedence

An empty-string env var is treated as unset.

---

## 3. Failure modes, and which are loud

**Loud — the container refuses to start**, with a message naming the module and key:

```
Invalid config for module [woven] with key [selfhostSeatLimit]
```

That happens for `0` (rejected deliberately, because upstream uses `0` to mean _no seats_, which
would make workspaces read-only), for a non-integer, and for a seat floor above `2147483647`
(the `seat_limit` column is int4). This is the good case: a bad env var fails the deploy
immediately rather than misbehaving later.

**Silent — the trap to actually worry about.** Env values are parsed with `parseInt`, so:

| You write | You get | Result                                       |
| --------- | ------- | -------------------------------------------- |
| `1_000`   | `1`     | a floor of 1 — passes validation, then inert |
| `1e6`     | `1`     | same                                         |
| `100GB`   | `100`   | a 100-**byte** floor, inert                  |
| `1,000`   | `1`     | same                                         |

No error, no visible effect, nothing to debug against — because a floor below the plan value is
correctly a no-op. **Use plain integers with no units, separators, or exponents.** This is pinned
by a test (`WOVEN_SELFHOST_SEAT_LIMIT=1_000` is asserted to produce `1`) and tracked as bead
`affine-fgo`, which proposes logging the resolved floors at startup so this becomes visible.

**Silent but safe.** A value that arrives through the unvalidated `config.json` path and is
unusable — non-numeric, fractional, out of range — makes the code **fail closed to the plan
value** rather than propagate. Without that guard, `"100GB"` would become `NaN`, and `BigInt(NaN)`
throws on every quota reconcile, which takes the whole quota subsystem down.

---

## 4. Changes are not instant

The quota projection is cached with a **10-minute TTL** and the rows survive a restart, and nothing
invalidates them at boot. After changing a floor, expect up to ten minutes before workspaces
reflect it — or immediately on the next membership or entitlement change in that workspace.

If you set a floor, restart, and still see the old limit, wait before investigating.

---

## 5. Verifying it took effect

After deploying, in order of increasing effort:

1. **Admin settings panel** — the three floors appear under a `woven` section with their current
   values. Fastest confirmation that the config reached the server.
2. **Members panel** of a self-hosted workspace — the header reads `Members (n/1000)` rather than
   `(n/10)`.
3. **Actually add an 11th member** and confirm the workspace does not go read-only.

**One thing that will look wrong and is not.** The user/plan settings panel will still show a
member limit of **10** even with a 1000 floor active. That number is derived from the plan name by
two independent code paths, server-side and client-side, and no floor can reach it. The members
panel — the one that governs behaviour — is correct. This is documented in `DESIGN.md` under
_Out of scope_.

---

## 6. Rollback

Remove the env vars (or set them back to `-1`) and restart. There is no migration, no schema
change, and no data to unwind — the floors only affect a projection that is recomputed on
reconcile. Workspaces already over the old limit will become read-only again once their projection
refreshes, which is the pre-existing upstream behaviour, so drop the member count below the plan
limit first if you need to roll back cleanly.
