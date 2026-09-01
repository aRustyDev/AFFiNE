import test from 'ava';

import {
  applyWovenSelfhostQuota,
  WOVEN_LIMIT_MAX,
  WOVEN_LIMIT_SHAPES,
  type WovenConfig,
} from '../woven-config';

const ONE_MB = 1024 * 1024;
const ONE_GB = 1024 * ONE_MB;

const inherit: WovenConfig = {
  selfhostSeatLimit: -1,
  selfhostStorageQuota: -1,
  selfhostBlobLimit: -1,
};

const planQuota = () => ({
  blobLimit: 100 * ONE_MB,
  storageQuota: 100 * ONE_GB,
  seatLimit: 10,
  historyPeriod: 30 * 24 * 60 * 60,
});

// seatLimit is `seatLimit?: number` on the real ResolvedQuota, so model "no seats granted"
// as the property being absent from a type that permits it — not absent from the type.
const seatlessQuota = (): {
  blobLimit: number;
  storageQuota: number;
  historyPeriod: number;
  seatLimit?: number;
} => ({ blobLimit: 1, storageQuota: 2, historyPeriod: 3 });

test('all -1 is an exact identity, including the object shape', t => {
  const quota = planQuota();
  const result = applyWovenSelfhostQuota(quota, inherit, true);

  t.deepEqual(result, quota);
});

test('inheriting preserves an absent seatLimit as absent', t => {
  const quota = seatlessQuota();
  const result = applyWovenSelfhostQuota(quota, inherit, true);

  t.deepEqual(result, quota);
  t.is(result, quota, 'the default path returns the same object, not a copy');
});

test('a floor above the plan value raises it', t => {
  const result = applyWovenSelfhostQuota(
    planQuota(),
    { ...inherit, selfhostSeatLimit: 1000 },
    true
  );

  t.is(result.seatLimit, 1000);
});

test('a floor below the plan value is a no-op — it never lowers a licensed plan', t => {
  const result = applyWovenSelfhostQuota(
    { ...planQuota(), seatLimit: 5000 },
    { ...inherit, selfhostSeatLimit: 1000 },
    true
  );

  t.is(result.seatLimit, 5000);
});

test('a seat floor applies when the plan grants no seats at all', t => {
  const quota = seatlessQuota();
  const result = applyWovenSelfhostQuota(
    quota,
    { ...inherit, selfhostSeatLimit: 1000 },
    true
  );

  t.is(result.seatLimit, 1000);
});

test('a storage-only floor does not materialize an absent seatLimit', t => {
  const quota = seatlessQuota();
  const result = applyWovenSelfhostQuota(
    quota,
    { ...inherit, selfhostStorageQuota: 900 },
    true
  );

  t.false('seatLimit' in result);
  t.is(result.storageQuota, 900, 'the configured floor still applies');
});

test('a blob-only floor does not materialize an absent seatLimit', t => {
  const quota = seatlessQuota();
  const result = applyWovenSelfhostQuota(
    quota,
    { ...inherit, selfhostBlobLimit: 900 },
    true
  );

  t.false('seatLimit' in result);
  t.is(result.blobLimit, 900, 'the configured floor still applies');
});

test('storage and blob floors are independent of the seat floor', t => {
  const result = applyWovenSelfhostQuota(
    planQuota(),
    {
      selfhostSeatLimit: -1,
      selfhostStorageQuota: 900 * ONE_GB,
      selfhostBlobLimit: 500 * ONE_MB,
    },
    true
  );

  t.is(result.storageQuota, 900 * ONE_GB);
  t.is(result.blobLimit, 500 * ONE_MB);
  t.is(result.seatLimit, 10);
});

test('not self-hosted is an exact identity even with floors set', t => {
  const quota = planQuota();
  const result = applyWovenSelfhostQuota(
    quota,
    {
      selfhostSeatLimit: 1000,
      selfhostStorageQuota: 900 * ONE_GB,
      selfhostBlobLimit: 500 * ONE_MB,
    },
    false
  );

  t.deepEqual(result, quota);
});

test('fields the helper does not own are passed through untouched', t => {
  const result = applyWovenSelfhostQuota(
    { ...planQuota(), copilotActionLimit: 10, seatQuota: 20 * ONE_GB },
    { ...inherit, selfhostSeatLimit: 1000 },
    true
  );

  t.is(result.copilotActionLimit, 10);
  t.is(result.seatQuota, 20 * ONE_GB);
  t.is(result.historyPeriod, 30 * 24 * 60 * 60);
});

test('the registered shapes reject 0 and point at -1', t => {
  for (const [key, shape] of Object.entries(WOVEN_LIMIT_SHAPES)) {
    t.false(shape.safeParse(0).success, `${key} must reject 0`);
    t.true(shape.safeParse(-1).success, `${key} must accept -1`);
    t.true(shape.safeParse(1000).success, `${key} must accept 1000`);
    t.false(shape.safeParse(-2).success, `${key} must reject -2`);
    t.false(shape.safeParse(1.5).success, `${key} must reject non-integers`);
  }

  const zeroMessage =
    WOVEN_LIMIT_SHAPES.selfhostSeatLimit.safeParse(0).error?.issues[0]?.message;
  t.is(zeroMessage, 'use -1 to inherit the plan value; 0 is not a valid limit');
});

test('each key carries the bound its column can actually hold', t => {
  t.true(WOVEN_LIMIT_SHAPES.selfhostSeatLimit.safeParse(2147483647).success);
  t.false(
    WOVEN_LIMIT_SHAPES.selfhostSeatLimit.safeParse(2147483648).success,
    'a seat floor above int4 would overflow the seat_limit column'
  );
  t.true(WOVEN_LIMIT_SHAPES.selfhostStorageQuota.safeParse(2147483648).success);
  t.true(
    WOVEN_LIMIT_SHAPES.selfhostStorageQuota.safeParse(Number.MAX_SAFE_INTEGER)
      .success
  );
  t.false(
    WOVEN_LIMIT_SHAPES.selfhostStorageQuota.safeParse(
      Number.MAX_SAFE_INTEGER + 1
    ).success
  );
  t.true(
    WOVEN_LIMIT_SHAPES.selfhostBlobLimit.safeParse(3221225472).success,
    'a 3GB per-file blob floor must be accepted — blob is not int4-bounded'
  );
  t.false(
    WOVEN_LIMIT_SHAPES.selfhostBlobLimit.safeParse(Number.MAX_SAFE_INTEGER + 1)
      .success
  );
});

// CONFIG_JSON_PATHS overrides and ConfigFactory.override are not schema-validated, so any of
// these can reach applyWovenSelfhostQuota at runtime even though WovenConfig's declared type is
// `number`. Every entry here must be rejected regardless of which key it targets or what that
// key's ceiling is — non-numeric, non-finite, fractional, zero, INHERIT itself, or a magnitude
// that loses precision as a JS number. Each must fail closed to the resolved plan value rather
// than producing NaN (which would throw in BigInt(...) on every reconcile, state.ts) or
// silently changing value en route.
//
// - 0.5 is the fractional case: Math.trunc(0.5) === 0, which is below the floor of 1, so it is
//   rejected unconditionally rather than merely being small — Math.max() never gets a chance to
//   coincidentally leave the resolved value alone for the wrong reason.
// - '', false, and [] are the falsy-coercion case: Number('') === Number(false) === Number([])
//   === 0, same rejection path as literal 0.
// - 0 and -1 (INHERIT passed as an explicit floor) both land below the floor of 1. 0 matters
//   because it must never materialize an absent seatLimit (see the dedicated test below); -1
//   matters because it must be rejected by usableFloor's own `>= 1` clause, not merely by the
//   allInherit fast path — the sentinel field below (set to 1 on whichever key is NOT under
//   test) guarantees every entry, including -1, actually reaches usableFloor.
// - '9007199254740993' and 1e30 are magnitudes Number.isSafeInteger rejects independent of any
//   per-key ceiling, because they lose precision as a JS number before WOVEN_LIMIT_MAX is ever
//   consulted — see the boundary-agreement test below for the ceiling-dependent case
//   (5000000000), which these are deliberately NOT part of.
const COMMON_GARBAGE: Array<[string, unknown]> = [
  ['a formatted byte count', '100GB'],
  ['a comma-grouped number', '1,000'],
  ['NaN', NaN],
  ['Infinity', Infinity],
  ['null', null],
  ['undefined', undefined],
  ['a fractional value', 0.5],
  ['an empty string', ''],
  ['false', false],
  ['an empty array', []],
  ['zero', 0],
  ['INHERIT passed as an explicit floor', -1],
  ['a magnitude that loses precision as a JS number', '9007199254740993'],
  ['a magnitude far beyond any column', 1e30],
];

test('a garbage seat floor fails closed to the plan value, never to NaN', t => {
  for (const [label, garbage] of COMMON_GARBAGE) {
    const floors = {
      ...inherit,
      selfhostSeatLimit: garbage,
      // sentinel: keeps allInherit false so -1 reaches usableFloor instead of the fast path
      selfhostBlobLimit: 1,
    } as unknown as WovenConfig;
    const result = applyWovenSelfhostQuota(planQuota(), floors, true);

    t.is(result.seatLimit, 10, `${label} must not change the seat floor`);
    t.true(Number.isFinite(result.seatLimit), `${label} must not produce NaN`);
  }
});

test('a garbage storage floor fails closed to the plan value, never to NaN', t => {
  for (const [label, garbage] of COMMON_GARBAGE) {
    const floors = {
      ...inherit,
      selfhostStorageQuota: garbage,
      // sentinel: keeps allInherit false so -1 reaches usableFloor instead of the fast path
      selfhostSeatLimit: 1,
    } as unknown as WovenConfig;
    const result = applyWovenSelfhostQuota(planQuota(), floors, true);

    t.is(
      result.storageQuota,
      100 * ONE_GB,
      `${label} must not change the storage floor`
    );
    t.true(
      Number.isFinite(result.storageQuota),
      `${label} must not produce NaN`
    );
  }
});

test('a garbage blob floor fails closed to the plan value, never to NaN', t => {
  for (const [label, garbage] of COMMON_GARBAGE) {
    const floors = {
      ...inherit,
      selfhostBlobLimit: garbage,
      // sentinel: keeps allInherit false so -1 reaches usableFloor instead of the fast path
      selfhostSeatLimit: 1,
    } as unknown as WovenConfig;
    const result = applyWovenSelfhostQuota(planQuota(), floors, true);

    t.is(
      result.blobLimit,
      100 * ONE_MB,
      `${label} must not change the blob floor`
    );
    t.true(Number.isFinite(result.blobLimit), `${label} must not produce NaN`);
  }
});

// 0 is the one COMMON_GARBAGE entry that can silently corrupt an ABSENT seatLimit rather than
// merely fail to raise a present one: with `planQuota()` (seatLimit: 10), Math.max(10, 0) is
// still 10 regardless of whether usableFloor's `>= 1` clause runs, so the loop above cannot
// catch that clause being removed. A seatless quota exposes it, because
// Math.max(undefined ?? 0, 0) === 0 would MATERIALIZE seatLimit as 0 if `>= 1` were dropped.
test('a seat floor of 0 leaves an absent seatLimit absent', t => {
  const quota = seatlessQuota();
  const result = applyWovenSelfhostQuota(
    quota,
    { ...inherit, selfhostSeatLimit: 0 },
    true
  );

  t.false(
    'seatLimit' in result,
    'a floor of 0 must not materialize an absent seatLimit'
  );
});

// WOVEN_LIMIT_MAX is the single source of truth both WOVEN_LIMIT_SHAPES (boot-time
// validation) and usableFloor (the runtime guard) read — see the comment on WOVEN_LIMIT_MAX in
// woven-config.ts. This test is what actually enforces that promise: it fails the moment either
// side is edited without the other, because it reads the ceiling from the shared constant, not
// from a value copied into the test.
test('the shape and the runtime guard agree on the boundary for every key', t => {
  // seat
  {
    const max = WOVEN_LIMIT_MAX.selfhostSeatLimit;
    t.true(
      WOVEN_LIMIT_SHAPES.selfhostSeatLimit.safeParse(max).success,
      'seat shape must accept its own max'
    );
    t.false(
      WOVEN_LIMIT_SHAPES.selfhostSeatLimit.safeParse(max + 1).success,
      'seat shape must reject one past its max'
    );

    const atMax = applyWovenSelfhostQuota(
      { ...planQuota(), seatLimit: 1 },
      { ...inherit, selfhostSeatLimit: max },
      true
    );
    t.is(
      atMax.seatLimit,
      max,
      'seat guard must accept the value the shape accepts'
    );

    const overMax = applyWovenSelfhostQuota(
      { ...planQuota(), seatLimit: 1 },
      { ...inherit, selfhostSeatLimit: max + 1 },
      true
    );
    t.is(
      overMax.seatLimit,
      1,
      'seat guard must refuse the value the shape refuses'
    );
  }

  // storage
  {
    const max = WOVEN_LIMIT_MAX.selfhostStorageQuota;
    t.true(
      WOVEN_LIMIT_SHAPES.selfhostStorageQuota.safeParse(max).success,
      'storage shape must accept its own max'
    );
    t.false(
      WOVEN_LIMIT_SHAPES.selfhostStorageQuota.safeParse(max + 1).success,
      'storage shape must reject one past its max'
    );

    const atMax = applyWovenSelfhostQuota(
      { ...planQuota(), storageQuota: 1 },
      { ...inherit, selfhostStorageQuota: max },
      true
    );
    t.is(
      atMax.storageQuota,
      max,
      'storage guard must accept the value the shape accepts'
    );

    const overMax = applyWovenSelfhostQuota(
      { ...planQuota(), storageQuota: 1 },
      { ...inherit, selfhostStorageQuota: max + 1 },
      true
    );
    t.is(
      overMax.storageQuota,
      1,
      'storage guard must refuse the value the shape refuses'
    );
  }

  // blob
  {
    const max = WOVEN_LIMIT_MAX.selfhostBlobLimit;
    t.true(
      WOVEN_LIMIT_SHAPES.selfhostBlobLimit.safeParse(max).success,
      'blob shape must accept its own max'
    );
    t.false(
      WOVEN_LIMIT_SHAPES.selfhostBlobLimit.safeParse(max + 1).success,
      'blob shape must reject one past its max'
    );

    const atMax = applyWovenSelfhostQuota(
      { ...planQuota(), blobLimit: 1 },
      { ...inherit, selfhostBlobLimit: max },
      true
    );
    t.is(
      atMax.blobLimit,
      max,
      'blob guard must accept the value the shape accepts'
    );

    const overMax = applyWovenSelfhostQuota(
      { ...planQuota(), blobLimit: 1 },
      { ...inherit, selfhostBlobLimit: max + 1 },
      true
    );
    t.is(
      overMax.blobLimit,
      1,
      'blob guard must refuse the value the shape refuses'
    );
  }
});

// 5000000000 is deliberately NOT in COMMON_GARBAGE: it is a safe integer within int4 distance of
// plausible, so it exercises the per-key ceiling itself rather than the shared non-numeric/
// non-finite checks — it must be rejected for seats (int4-bounded, WOVEN_LIMIT_MAX.
// selfhostSeatLimit) but accepted as a legitimate floor for storage/blob (MAX_SAFE_INTEGER-
// bounded). A single shared table cannot assert both outcomes for the same input.
test('5000000000 is rejected for the seat floor but accepted for storage and blob', t => {
  const seatResult = applyWovenSelfhostQuota(
    planQuota(),
    { ...inherit, selfhostSeatLimit: 5_000_000_000 },
    true
  );
  t.is(
    seatResult.seatLimit,
    10,
    'a seat floor above int4 (2147483647) must be rejected, not overflow seat_limit'
  );

  // resolved storageQuota/blobLimit must start BELOW 5000000000, or Math.max() would leave the
  // assertion trivially true regardless of whether the floor was actually accepted (planQuota()'s
  // 100GB default is already above it, so it is deliberately not used here).
  const storageResult = applyWovenSelfhostQuota(
    { ...planQuota(), storageQuota: 1 },
    { ...inherit, selfhostStorageQuota: 5_000_000_000 },
    true
  );
  t.is(
    storageResult.storageQuota,
    5_000_000_000,
    'storage is bounded by MAX_SAFE_INTEGER, not int4 — this magnitude is a valid floor'
  );

  const blobResult = applyWovenSelfhostQuota(
    { ...planQuota(), blobLimit: 1 },
    { ...inherit, selfhostBlobLimit: 5_000_000_000 },
    true
  );
  t.is(
    blobResult.blobLimit,
    5_000_000_000,
    'blob is bounded by MAX_SAFE_INTEGER, not int4 — this magnitude is a valid floor'
  );
});

test('the selfhosted parameter defaults to env.selfhosted', t => {
  const previous = globalThis.env.DEPLOYMENT_TYPE;
  try {
    // @ts-expect-error test mutates the env singleton
    globalThis.env.DEPLOYMENT_TYPE = 'selfhosted';
    const floored = applyWovenSelfhostQuota(planQuota(), {
      ...inherit,
      selfhostSeatLimit: 1000,
    });
    t.is(floored.seatLimit, 1000, 'floors apply when env says selfhosted');

    // @ts-expect-error test mutates the env singleton
    globalThis.env.DEPLOYMENT_TYPE = 'affine';
    const untouched = applyWovenSelfhostQuota(planQuota(), {
      ...inherit,
      selfhostSeatLimit: 1000,
    });
    t.is(untouched.seatLimit, 10, 'floors are inert when env says cloud');
  } finally {
    // @ts-expect-error restore mutable test env singleton
    globalThis.env.DEPLOYMENT_TYPE = previous;
  }
});
