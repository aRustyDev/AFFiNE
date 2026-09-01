import { type Prisma, type PrismaClient } from '@prisma/client';

import { isUndefinedTable } from './prisma-errors';

/**
 * `app_configs` id for the deployment stamp.
 *
 * The `$` prefix is deliberate and load-bearing. `ServerService.loadDbOverrides()`
 * merges every `app_configs` row into the runtime config tree, but `override()`
 * ignores unknown config modules — so an id whose first segment can never match
 * a registered module name is inert. See grounding G3 and design D6. Do not
 * change this to a dotted, module-shaped id.
 */
export const DEPLOYMENT_STAMP_ID = '$deployment';

export type AdoptionMode = 'fresh-install' | 'implicit' | 'explicit';

export interface BuildRef {
  version: string;
  buildSha: string;
}

export interface DeploymentStamp {
  deploymentId: string;
  adoptedAt: string;
  adoptionMode: AdoptionMode;
  adoptedBy: BuildRef;
  lastMigratedBy?: BuildRef & { at: string };
}

export type IdentityState =
  | { kind: 'absent' }
  | { kind: 'unchecked'; stamp: DeploymentStamp }
  | { kind: 'match'; stamp: DeploymentStamp }
  | { kind: 'mismatch'; stamp: DeploymentStamp; configured: string }
  /**
   * A stamp row exists but could not be parsed. Deliberately distinct from
   * `absent`: an unreadable row is evidence of a PRIOR adoption, and treating
   * it as "no stamp" would let the gate run again and overwrite that
   * evidence. See `compat.ts`, which turns this into a refusing
   * `IDENTITY_MISMATCH` regardless of whether a deployment id is configured —
   * we cannot confirm whose database this is, so we must not clobber it.
   */
  | { kind: 'corrupt' };

/**
 * The comparison below is exact string equality — no trimming or other
 * normalization. That's deliberate: this function must fail loudly on a
 * near-miss rather than silently accept one. But it means whoever supplies
 * `configured` owns getting it exact — a trailing newline from a
 * mounted-secret-file value would otherwise read as a genuine `mismatch` and
 * refuse to boot. Task 3 owns that env/secret boundary and is responsible for
 * trimming before the value ever reaches here.
 *
 * `corrupt` short-circuits everything else, including a missing `configured`
 * id — an unreadable stamp is refused unconditionally, not merely
 * "unchecked".
 */
export function evaluateIdentity(
  stamp: DeploymentStamp | null,
  configured: string | null,
  corrupt = false
): IdentityState {
  if (corrupt) {
    return { kind: 'corrupt' };
  }
  if (!stamp) {
    return { kind: 'absent' };
  }
  if (!configured) {
    return { kind: 'unchecked', stamp };
  }
  return stamp.deploymentId === configured
    ? { kind: 'match', stamp }
    : { kind: 'mismatch', stamp, configured };
}

const ADOPTION_MODES: ReadonlySet<string> = new Set<AdoptionMode>([
  'fresh-install',
  'implicit',
  'explicit',
]);

function isBuildRef(value: unknown): value is BuildRef {
  if (!value || typeof value !== 'object') {
    return false;
  }
  const ref = value as Partial<BuildRef>;
  return (
    typeof ref.version === 'string' &&
    ref.version.length > 0 &&
    typeof ref.buildSha === 'string' &&
    ref.buildSha.length > 0
  );
}

/**
 * Validates every field a caller might dereference, not just `deploymentId`.
 * A stamp that parsed as "valid" with `adoptionMode`/`adoptedBy` silently
 * `undefined` would let a renderer crash on `adoptedBy.version` later — in a
 * command specified to always exit 0. A partial stamp is corrupt, not a
 * valid stamp with holes in it.
 */
function parseStamp(value: unknown): DeploymentStamp | null {
  if (!value || typeof value !== 'object') {
    return null;
  }
  const candidate = value as Partial<DeploymentStamp>;
  if (typeof candidate.deploymentId !== 'string' || !candidate.deploymentId) {
    return null;
  }
  if (typeof candidate.adoptedAt !== 'string' || !candidate.adoptedAt) {
    return null;
  }
  if (
    typeof candidate.adoptionMode !== 'string' ||
    !ADOPTION_MODES.has(candidate.adoptionMode)
  ) {
    return null;
  }
  if (!isBuildRef(candidate.adoptedBy)) {
    return null;
  }
  return candidate as DeploymentStamp;
}

export interface StampRead {
  /** The parsed stamp, or `null` when there is none (or it was corrupt). */
  stamp: DeploymentStamp | null;
  /**
   * `true` when a row exists but failed to parse. Distinct from `stamp ===
   * null` on its own, which is also true for the ordinary "no row yet" case —
   * callers that only care about presence can ignore this, but the adoption
   * gate must not conflate the two (see `IdentityState.corrupt`).
   */
  corrupt: boolean;
}

/**
 * Reads the deployment stamp. Tolerates a missing `app_configs` table the
 * same way `readDbState` tolerates a missing `_prisma_migrations`/`users`
 * table: the predeploy gate runs BEFORE `prisma migrate deploy`, so on a
 * fresh install `app_configs` does not exist yet, and that is "no stamp",
 * not an error.
 */
export async function readStamp(db: PrismaClient): Promise<StampRead> {
  let row: { value: unknown } | null;
  try {
    row = await db.appConfig.findUnique({
      where: { id: DEPLOYMENT_STAMP_ID },
    });
  } catch (error) {
    if (!isUndefinedTable(error)) {
      throw error;
    }
    return { stamp: null, corrupt: false };
  }

  if (!row) {
    return { stamp: null, corrupt: false };
  }

  const stamp = parseStamp(row.value);
  return stamp ? { stamp, corrupt: false } : { stamp: null, corrupt: true };
}

/**
 * Writes the deployment stamp. Unlike `readStamp`, this does NOT degrade on a
 * missing `app_configs` table: after the `db check` / `stamp()` split, this
 * is only ever called from `DbCompatService.stamp()`, which runs AFTER
 * `prisma migrate deploy` — so `app_configs` not existing at this point is a
 * caller bug, not a normal pre-migration state, and deserves a clear error
 * rather than a raw `P2021`.
 */
export async function writeStamp(
  db: PrismaClient,
  stamp: DeploymentStamp
): Promise<void> {
  const value = stamp as unknown as Prisma.InputJsonValue;
  try {
    await db.appConfig.upsert({
      where: { id: DEPLOYMENT_STAMP_ID },
      update: { value },
      create: { id: DEPLOYMENT_STAMP_ID, value },
    });
  } catch (error) {
    if (isUndefinedTable(error)) {
      throw new Error(
        'writeStamp() was called before app_configs exists. This is a caller ' +
          'bug: the deployment stamp can only be written after `prisma migrate ' +
          'deploy` has run — see DbCompatService.stamp(), which is the only ' +
          'intended caller.'
      );
    }
    throw error;
  }
}
