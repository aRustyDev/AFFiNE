// WOVEN FORK-LOCAL — fork-owned file, rebase-safe by construction.
//
// Companion to the FORK-LOCAL CORE PATCH in ./state.ts (bead affine-vap). All the logic lives
// here so that upstream owns only the two call sites; see
// .claude/plans/selfhost-quota-limits/PLAN.md.
//
// Convention: -1 inherits the plan value (default, so an unconfigured server behaves exactly
// like upstream), N >= 1 is a FLOOR applied via max(). 0 is rejected: upstream already uses 0
// to mean "no seats" (state.ts, `quota.seatLimit ?? 0`), which drives overcapacityMemberCount
// and would make the workspace readonly.
//
// getDefaultConfig() validates defaults and env, but CONFIG_JSON_PATHS overrides
// (~/.affine/config/config.json, the primary self-host mechanism) and ConfigFactory.override
// are NOT validated. A fractional, non-numeric, OR out-of-range value (e.g. "100GB", "1,000",
// null, 5000000000) can therefore reach applyWovenSelfhostQuota; the real guarantee this file
// provides is that such a value fails closed to the resolved plan value — via usableFloor()
// below, bounded by WOVEN_LIMIT_MAX — rather than propagating NaN into Math.max()/BigInt(...) in
// state.ts, or a magnitude that overflows the destination column, not schema validation at every
// entry point.
import { z } from 'zod';

import { defineModuleConfig } from '../../base';

export interface WovenConfig {
  selfhostSeatLimit: number;
  selfhostStorageQuota: number;
  selfhostBlobLimit: number;
}

declare global {
  interface AppConfigSchema {
    woven: WovenConfig;
  }
}

const INHERIT = -1;

const INT32_MAX = 2147483647;

// Single source of truth for the per-key ceiling, read by BOTH the boot-time zod validation
// (WOVEN_LIMIT_SHAPES below) and the runtime guard (usableFloor) that CONFIG_JSON_PATHS
// overrides and ConfigFactory.override must pass through unvalidated. A bound defined in two
// places drifts; a bound defined once and read twice provably cannot disagree.
export const WOVEN_LIMIT_MAX = {
  // seat_limit is `Int @db.Integer` (int4) in schema.prisma and is read as i32 by the native
  // invite-abuse policy, so the seat floor cannot exceed int4.
  selfhostSeatLimit: INT32_MAX,
  // storage_quota / blob_limit are `BigInt @db.BigInt`, but the value passes through a JS
  // number and `BigInt(...)` in state.ts, so MAX_SAFE_INTEGER — not the int8 range — is the
  // real ceiling. Widening this would admit a config value that silently changes en route.
  selfhostStorageQuota: Number.MAX_SAFE_INTEGER,
  selfhostBlobLimit: Number.MAX_SAFE_INTEGER,
} as const;

function limitShape(max: number) {
  return z
    .number()
    .int()
    .min(INHERIT)
    .max(max)
    .refine(value => value !== 0, {
      message: 'use -1 to inherit the plan value; 0 is not a valid limit',
    });
}

export const WOVEN_LIMIT_SHAPES = {
  selfhostSeatLimit: limitShape(WOVEN_LIMIT_MAX.selfhostSeatLimit),
  selfhostStorageQuota: limitShape(WOVEN_LIMIT_MAX.selfhostStorageQuota),
  selfhostBlobLimit: limitShape(WOVEN_LIMIT_MAX.selfhostBlobLimit),
};

defineModuleConfig('woven', {
  selfhostSeatLimit: {
    desc: 'Minimum workspace member limit on self-hosted deployments. -1 inherits the plan value (upstream behavior); N >= 1 raises the limit to at least N and never lowers a licensed plan. Ignored on cloud deployments. Plain integer, no units or separators (e.g. 1000, not "1,000"). Takes effect within 10 minutes, or immediately on the next membership/entitlement change.',
    default: INHERIT,
    shape: WOVEN_LIMIT_SHAPES.selfhostSeatLimit,
    env: ['WOVEN_SELFHOST_SEAT_LIMIT', 'integer'],
  },
  selfhostStorageQuota: {
    desc: 'Minimum total storage quota in BYTES on self-hosted deployments; applies to both the workspace and user quota projections. -1 inherits the plan value (upstream behavior). Ignored on cloud deployments. Plain integer byte count, no units or separators (e.g. 107374182400, not "100GB"). Takes effect within 10 minutes, or immediately on the next membership/entitlement change.',
    default: INHERIT,
    shape: WOVEN_LIMIT_SHAPES.selfhostStorageQuota,
    env: ['WOVEN_SELFHOST_STORAGE_QUOTA', 'integer'],
  },
  selfhostBlobLimit: {
    desc: 'Minimum per-file blob size limit in BYTES on self-hosted deployments. -1 inherits the plan value (upstream behavior). Ignored on cloud deployments. Plain integer byte count, no units or separators (e.g. 104857600, not "100MB"). Takes effect within 10 minutes, or immediately on the next membership/entitlement change.',
    default: INHERIT,
    shape: WOVEN_LIMIT_SHAPES.selfhostBlobLimit,
    env: ['WOVEN_SELFHOST_BLOB_LIMIT', 'integer'],
  },
});

type Floorable = {
  blobLimit: number;
  storageQuota: number;
  seatLimit?: number;
};

// configured is coerced and range-checked at this trust boundary: CONFIG_JSON_PATHS overrides
// and ConfigFactory.override are not schema-validated, so a fractional, non-numeric, or
// out-of-range override (a typo'd byte count, "100GB", "1,000", null, undefined, NaN, Infinity,
// 5000000000 for a seat floor, "9007199254740993") must not reach BigInt(...) in state.ts and
// throw RangeError on every reconcile, must not reach a Prisma int4 write and throw there
// either, and must not silently change value en route (Number.isSafeInteger, not isFinite,
// rejects magnitudes that lose precision passing through a JS number). Fail closed to the plan
// value: a floor we cannot make sense of, or that would not fit the column it is destined for,
// must never reach Math.max(). INHERIT (-1) collapses to the same "leave resolved alone" outcome
// as any other unusable value, since -1 < 1 — no separate INHERIT check is needed. `max` is
// always one of WOVEN_LIMIT_MAX's values, the same bound the zod shape enforces at boot.
function usableFloor(configured: unknown, max: number): number | null {
  const floor = Math.trunc(Number(configured));
  return Number.isSafeInteger(floor) && floor >= 1 && floor <= max
    ? floor
    : null;
}

function floorMaybeAbsent(
  resolved: number | undefined,
  configured: unknown,
  max: number
) {
  const floor = usableFloor(configured, max);
  return floor === null ? resolved : Math.max(resolved ?? 0, floor);
}

function floorPresent(resolved: number, configured: unknown, max: number) {
  const floor = usableFloor(configured, max);
  return floor === null ? resolved : Math.max(resolved, floor);
}

export function applyWovenSelfhostQuota<T extends Floorable>(
  quota: T,
  floors: WovenConfig,
  selfhosted: boolean = env.selfhosted
): T {
  const allInherit =
    floors.selfhostSeatLimit === INHERIT &&
    floors.selfhostStorageQuota === INHERIT &&
    floors.selfhostBlobLimit === INHERIT;

  // Fast path only — NOT where the absent-seatLimit guarantee lives. Configuring even one
  // floor (e.g. storage only) still routes seatLimit through the conditional spread below, so
  // the guarantee that an absent seatLimit stays absent is unconditional, not tied to this
  // early return.
  if (!selfhosted || allInherit) {
    return quota;
  }

  const seatLimit = floorMaybeAbsent(
    quota.seatLimit,
    floors.selfhostSeatLimit,
    WOVEN_LIMIT_MAX.selfhostSeatLimit
  );

  return {
    ...quota,
    storageQuota: floorPresent(
      quota.storageQuota,
      floors.selfhostStorageQuota,
      WOVEN_LIMIT_MAX.selfhostStorageQuota
    ),
    blobLimit: floorPresent(
      quota.blobLimit,
      floors.selfhostBlobLimit,
      WOVEN_LIMIT_MAX.selfhostBlobLimit
    ),
    // Conditionally spread rather than always assigning `seatLimit: seatLimit`, so an
    // undefined result never materializes the key — `{ ...quota, seatLimit: undefined }`
    // would add an own enumerable property that upstream never produces.
    ...(seatLimit === undefined ? {} : { seatLimit }),
  };
}
