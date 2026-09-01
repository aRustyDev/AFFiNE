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
// seat_limit is `Int @db.Integer` in schema.prisma and is read as i32 by the native
// invite-abuse policy, so the seat floor cannot exceed int4.
const INT32_MAX = 2147483647;

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

defineModuleConfig('woven', {
  selfhostSeatLimit: {
    desc: 'Minimum workspace member limit on self-hosted deployments. -1 inherits the plan value (upstream behavior); N >= 1 raises the limit to at least N and never lowers a licensed plan. Ignored on cloud deployments.',
    default: INHERIT,
    shape: limitShape(INT32_MAX),
    env: ['WOVEN_SELFHOST_SEAT_LIMIT', 'integer'],
  },
  selfhostStorageQuota: {
    desc: 'Minimum total workspace storage quota in BYTES on self-hosted deployments. -1 inherits the plan value (upstream behavior). Ignored on cloud deployments.',
    default: INHERIT,
    shape: limitShape(Number.MAX_SAFE_INTEGER),
    env: ['WOVEN_SELFHOST_STORAGE_QUOTA', 'integer'],
  },
  selfhostBlobLimit: {
    desc: 'Minimum per-file blob size limit in BYTES on self-hosted deployments. -1 inherits the plan value (upstream behavior). Ignored on cloud deployments.',
    default: INHERIT,
    shape: limitShape(Number.MAX_SAFE_INTEGER),
    env: ['WOVEN_SELFHOST_BLOB_LIMIT', 'integer'],
  },
});

type Floorable = {
  blobLimit: number;
  storageQuota: number;
  seatLimit?: number;
};

// Identity when configured === INHERIT — including preserving an absent seatLimit as absent,
// so "unconfigured" is provably indistinguishable from upstream rather than merely equivalent.
function floorOptional(resolved: number | undefined, configured: number) {
  return configured === INHERIT
    ? resolved
    : Math.max(resolved ?? 0, configured);
}

function floorRequired(resolved: number, configured: number) {
  return configured === INHERIT ? resolved : Math.max(resolved, configured);
}

export function applyWovenSelfhostQuota<T extends Floorable>(
  quota: T,
  floors: WovenConfig,
  selfhosted: boolean = env.selfhosted
): T {
  if (!selfhosted) {
    return quota;
  }

  return {
    ...quota,
    seatLimit: floorOptional(quota.seatLimit, floors.selfhostSeatLimit),
    storageQuota: floorRequired(
      quota.storageQuota,
      floors.selfhostStorageQuota
    ),
    blobLimit: floorRequired(quota.blobLimit, floors.selfhostBlobLimit),
  };
}
