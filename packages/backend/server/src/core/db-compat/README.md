# Database compatibility and adoption (`affine-tc6`)

Fork-owned. Refuses to start or migrate when the database does not match this binary, records
adoption of a pre-existing database as a durable decision rather than an inference from user count,
and reports whether rollback will be possible.

Design and rationale: `.claude/plans/adopt-existing-database/DESIGN.md`. Every design decision
referenced below as `Dnn` is in `findings/decision-log.md`; measured facts are `Gnn` in
`findings/grounding.md`.

## What problem this solves

Before this, a server assumed it either owned a virgin database or one it had migrated itself.
`ServerService.initialized()` is literally `models.user.count() > 0`, so a restored or relocated
database was adopted **implicitly**, with no compatibility check at all. And because deployment is
forward-only, starting an older binary against a database migrated by a newer one failed at request
time rather than at boot.

## Commands

Two invocation forms, same CLI:

| Where                         | Form                                                           |
| ----------------------------- | -------------------------------------------------------------- |
| In the image / a built server | `yarn cli db <subcommand>` (cwd `/app`, runs `dist/main.js`)   |
| A source checkout (no bundle) | `yarn workspace @affine/server data-migration db <subcommand>` |

`data-migration` is `cross-env NODE_ENV=development SERVER_FLAVOR=script r ./src/index.ts` — the
dev entry point to the same CLI. Its name is historical and it accepts any subcommand; use it to
audit a merge locally without a full rspack build.

### `db status`

The dry-run report: verdict, applied/known counts, pending migrations by tier with the matched DDL,
identity state, and an explicit `rollback after applying:` line. **Always exits 0**, including when
the database is unreachable — it is the diagnostic you reach for when something is already wrong,
so it must never itself fail to produce a report. `--json` for machine use (it suppresses the Nest
logger so stdout is pure JSON).

### `db check`

The gate. **Writes nothing.** Exits non-zero with a precise reason when the database is unsafe for
this binary to migrate. Run automatically by `predeploy` before any migration.

### `db stamp`

Records the deployment stamp. Idempotent. Run automatically by `predeploy` **after** migrations —
it has to be after, because the stamp lives in `app_configs`, which does not exist on a fresh
install until `prisma migrate deploy` has run (D17). On an already-stamped database it updates only
`lastMigratedBy`; if the verdict refuses, it declines to write and says why.

## Verdicts

| Verdict             | Meaning                                              | `db check`                            | Server boot             |
| ------------------- | ---------------------------------------------------- | ------------------------------------- | ----------------------- |
| `VIRGIN`            | no migration history, no data                        | proceed                               | proceed                 |
| `EQUAL`             | applied matches this binary                          | proceed                               | proceed                 |
| `DB_BEHIND`         | this binary has migrations the database lacks        | migrate, subject to the adoption gate | proceed                 |
| `DB_AHEAD`          | the database carries migrations this binary lacks    | **refuse**                            | **refuse**              |
| `DIVERGED`          | each side has what the other lacks                   | **refuse**                            | **refuse**              |
| `IDENTITY_MISMATCH` | the stamp names another deployment, or is unreadable | **refuse**                            | **refuse**              |
| `MIGRATION_FAILED`  | a migration is unfinished and not rolled back        | **refuse**                            | **refuse**              |
| `SCHEMA_INCOMPLETE` | migrations recorded but a core table is absent       | **refuse**                            | **refuse**              |
| `UNREADABLE`        | the migrations directory could not be located        | **refuse**                            | log ERROR, **continue** |

`UNREADABLE` is asymmetric on purpose (D9). A predeploy wedge is safe — the new pod stalls in
`Init` and the old fleet keeps serving — but refusing to _boot_ over a packaging fault would take
the fleet down for a non-safety reason.

## Environment variables

Read directly from `process.env` and deliberately **not** registered as app config (D13), so they
cannot be overridden from the `app_configs` table and do not appear in the admin UI. A database row
must not be able to switch off the guard that judges that database.

| Variable                  | Effect                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `AFFINE_DEPLOYMENT_ID`    | Asserts which deployment this is. When set and the stamp names another, the server refuses. Unset ⇒ identity unchecked.    |
| `AFFINE_DB_ADOPT=1`       | Confirms a pre-existing, unstamped, populated database is intended even across a `BLOCKING` migration.                     |
| `AFFINE_DB_COMPAT_SKIP=1` | **Incident bypass.** Suppresses the boot refusal only — never `db check` — and logs at ERROR on every boot. Not a setting. |

## Enabling wrong-database detection

Identity has to be asserted from **outside** the database, or the check is circular: an id read
_out_ of a database cannot tell you it is the wrong database (D5). On first adoption with no
`AFFINE_DEPLOYMENT_ID` set, a UUID is minted, stored and logged:

```
deployment identity minted as <uuid>; set AFFINE_DEPLOYMENT_ID=<uuid> to enable wrong-database detection
```

Pin that value in the chart's `extraEnv` — values-only, no template change. Until it is set,
`IDENTITY_MISMATCH` cannot fire; the `DB_AHEAD` guard is unaffected and always active.

The logged id is always the **persisted** one. That matters: an earlier version minted per-process,
so two pods starting together could log an id the database did not hold, and an operator following
the instruction would get `IDENTITY_MISMATCH` and a server that refuses to boot (D22).

## The adoption gate

On first contact with a populated database carrying no stamp — every existing deployment, the
moment this ships:

- `EQUAL`, or `DB_BEHIND` where every pending migration is `EXPAND`/`DESTRUCTIVE` → **auto-adopt**,
  stamped and logged as implicit.
- `DB_BEHIND` with any `BLOCKING` pending migration → **refuse** unless `AFFINE_DB_ADOPT=1`.

"Populated" means users **or workspaces** (G7a). It deliberately does not reuse
`ServerService.initialized()`'s user count: AFFiNE preserves workspaces, documents and blobs when
users are deleted — `Workspace` has no foreign key to `User` — so a production clone with `users`
truncated to scrub PII still holds all its content, and must still be gated.

## Recovering from a refusal

1. Run `db status` to see the verdict and its evidence. It exits 0 even when the database is
   unreachable, so it is safe to run first.
2. `DB_AHEAD` — you are deploying an **older** image than the one that migrated this database.
   Deploy the newer image, or restore a backup from before the newer one ran. Do not force it: the
   schema has moved past what this binary can read.
3. `IDENTITY_MISMATCH` — check `AFFINE_DEPLOYMENT_ID` against the stamp `db status` reports. Either
   the variable is wrong or the connection string points at another deployment's database.
4. `SCHEMA_INCOMPLETE` — the migration history records applied migrations but a core table is
   missing. Usually a partial restore. Finish the restore rather than migrating forward.
5. `MIGRATION_FAILED` — a previous migration did not finish. Resolve it with
   `prisma migrate resolve` before retrying.
6. Adoption refused on a `BLOCKING` migration — take a backup, **verify it restores**, then set
   `AFFINE_DB_ADOPT=1`.

`AFFINE_DB_COMPAT_SKIP=1` is the last resort, for when the guard itself is wrong. It affects only
the boot check, logs at ERROR every boot, and cannot get a deploy past `db check`.

## What this does not protect

An image built **before** this shipped cannot refuse anything. Rollback across
`20260714000001_drop_legacy_permission_and_subscription` — a contracting migration already inside
the pinned image — remains unprotected, and a verified-restorable backup is the only net for it.
This stops the next one.
