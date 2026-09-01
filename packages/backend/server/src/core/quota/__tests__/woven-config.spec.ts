import test from 'ava';

import {
  applyWovenSelfhostQuota,
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
// `number`. Each must fail closed to the resolved plan value rather than producing NaN, which
// would throw in BigInt(...) on every reconcile (state.ts) and take the quota subsystem down.
// 0.5 is the fractional case: Math.trunc(0.5) === 0, which is below the floor of 1, so it is
// rejected unconditionally rather than merely being small — Math.max() never gets a chance to
// coincidentally leave the resolved value alone for the wrong reason.
const GARBAGE_FLOORS: Array<[string, unknown]> = [
  ['a formatted byte count', '100GB'],
  ['a comma-grouped number', '1,000'],
  ['NaN', NaN],
  ['Infinity', Infinity],
  ['null', null],
  ['undefined', undefined],
  ['a fractional value', 0.5],
];

test('a garbage seat floor fails closed to the plan value, never to NaN', t => {
  for (const [label, garbage] of GARBAGE_FLOORS) {
    const floors = {
      ...inherit,
      selfhostSeatLimit: garbage,
    } as unknown as WovenConfig;
    const result = applyWovenSelfhostQuota(planQuota(), floors, true);

    t.is(result.seatLimit, 10, `${label} must not change the seat floor`);
    t.true(Number.isFinite(result.seatLimit), `${label} must not produce NaN`);
  }
});

test('a garbage storage floor fails closed to the plan value, never to NaN', t => {
  for (const [label, garbage] of GARBAGE_FLOORS) {
    const floors = {
      ...inherit,
      selfhostStorageQuota: garbage,
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
  for (const [label, garbage] of GARBAGE_FLOORS) {
    const floors = {
      ...inherit,
      selfhostBlobLimit: garbage,
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
