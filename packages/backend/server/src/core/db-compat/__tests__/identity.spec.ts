import { PrismaClient } from '@prisma/client';
import test from 'ava';
import { set } from 'lodash-es';

import { override } from '../../../base/config/register';
import {
  DEPLOYMENT_STAMP_ID,
  type DeploymentStamp,
  evaluateIdentity,
  readStamp,
  writeStamp,
} from '../identity';

const db = new PrismaClient();

function requireDatabaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) {
    throw new Error(
      'DATABASE_URL must be set to run identity.spec.ts against a real Postgres instance'
    );
  }
  return url;
}

function scratchClient(schema: string): PrismaClient {
  const url = new URL(requireDatabaseUrl());
  url.searchParams.set('schema', schema);
  return new PrismaClient({ datasources: { db: { url: url.toString() } } });
}

async function withEmptySchema<T>(
  name: string,
  fn: (client: PrismaClient) => Promise<T>
): Promise<T> {
  // Drop before create so a leftover schema from an abnormally-terminated
  // previous run doesn't turn into a duplicate-schema error instead of the
  // test just working — this database may be shared with other active work.
  await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${name}" CASCADE`);
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${name}"`);
  const scratch = scratchClient(name);
  try {
    return await fn(scratch);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${name}" CASCADE`);
  }
}

test.before(async () => {
  await db.$connect();
});

test.beforeEach(async () => {
  await db.appConfig.deleteMany({ where: { id: DEPLOYMENT_STAMP_ID } });
});

test.after.always(async () => {
  await db.appConfig.deleteMany({ where: { id: DEPLOYMENT_STAMP_ID } });
  await db.$disconnect();
});

const stamp = (deploymentId: string): DeploymentStamp => ({
  deploymentId,
  adoptedAt: '2026-01-01T00:00:00.000Z',
  adoptionMode: 'explicit',
  adoptedBy: { version: '0.27.0', buildSha: 'abc1234' },
});

test('readStamp returns no stamp and no corruption when absent', async t => {
  const result = await readStamp(db);
  t.is(result.stamp, null);
  t.false(result.corrupt);
});

test('writeStamp then readStamp round-trips', async t => {
  await writeStamp(db, stamp('prod-a'));
  const { stamp: read, corrupt } = await readStamp(db);
  t.is(read?.deploymentId, 'prod-a');
  t.is(read?.adoptionMode, 'explicit');
  t.false(corrupt);
});

test('writeStamp is an upsert, not a duplicate-key error', async t => {
  await writeStamp(db, stamp('prod-a'));
  await writeStamp(db, { ...stamp('prod-a'), adoptionMode: 'implicit' });
  t.is((await readStamp(db)).stamp?.adoptionMode, 'implicit');
  t.is(await db.appConfig.count({ where: { id: DEPLOYMENT_STAMP_ID } }), 1);
});

// Critical fix: the predeploy gate runs BEFORE `prisma migrate deploy`, so on
// a fresh install `app_configs` does not exist yet. Before this fix,
// `readStamp` threw a raw P2021 in that state, which meant `db check`/`db
// status` — specified to always exit 0 — crashed instead, and fresh installs
// could not deploy at all.
test('readStamp degrades to "no stamp" rather than throwing when app_configs does not exist yet', async t => {
  await withEmptySchema('db_compat_identity_no_table', async scratch => {
    const result = await readStamp(scratch);
    t.is(result.stamp, null);
    t.false(result.corrupt);
  });
});

// The corollary of the above: writeStamp() genuinely cannot succeed before
// app_configs exists, so calling it there is a caller bug (it must only be
// invoked from DbCompatService.stamp(), which runs AFTER migrations). It
// should say so clearly rather than surface a raw P2021.
test('writeStamp throws a clear caller-bug error rather than a raw P2021 pre-migration', async t => {
  await withEmptySchema('db_compat_identity_write_no_table', async scratch => {
    const error = await t.throwsAsync(() =>
      writeStamp(scratch, stamp('prod-a'))
    );
    t.regex(error!.message, /app_configs/i);
  });
});

// A row exists but cannot be parsed. This must be distinguished from "no
// stamp": corruption is evidence of a prior adoption that must not be
// silently overwritten (see the buildReport corrupt-stamp test in
// compat.spec.ts, and the "an already-stamped database" tests in
// service.spec.ts) — fail CLOSED, not open.
test('readStamp classifies a malformed row as corrupt, not absent', async t => {
  await db.appConfig.create({
    data: { id: DEPLOYMENT_STAMP_ID, value: { nope: true } },
  });
  const { stamp: read, corrupt } = await readStamp(db);
  t.is(read, null);
  t.true(corrupt);
});

// Important fix: a stamp missing `adoptionMode`/`adoptedBy` used to parse
// successfully (as `undefined` fields), and a renderer reading
// `adoptedBy.version` would crash — in the command specified to always exit
// 0. A partial stamp like this must be corrupt, not a "valid" stamp with
// holes in it.
test('readStamp rejects a stamp with a missing adoptionMode/adoptedBy as corrupt', async t => {
  await db.appConfig.create({
    data: {
      id: DEPLOYMENT_STAMP_ID,
      value: { deploymentId: 'prod-a', adoptedAt: '2026-01-01T00:00:00.000Z' },
    },
  });
  const { stamp: read, corrupt } = await readStamp(db);
  t.is(read, null);
  t.true(corrupt);
});

test('readStamp rejects an unrecognised adoptionMode as corrupt', async t => {
  await db.appConfig.create({
    data: {
      id: DEPLOYMENT_STAMP_ID,
      value: {
        deploymentId: 'prod-a',
        adoptedAt: '2026-01-01T00:00:00.000Z',
        adoptionMode: 'sideloaded',
        adoptedBy: { version: '0.27.0', buildSha: 'abc' },
      },
    },
  });
  const { corrupt } = await readStamp(db);
  t.true(corrupt);
});

test('readStamp rejects an empty adoptedAt as corrupt', async t => {
  await db.appConfig.create({
    data: {
      id: DEPLOYMENT_STAMP_ID,
      value: {
        deploymentId: 'prod-a',
        adoptedAt: '',
        adoptionMode: 'explicit',
        adoptedBy: { version: '0.27.0', buildSha: 'abc' },
      },
    },
  });
  const { corrupt } = await readStamp(db);
  t.true(corrupt);
});

// Tests the ACTUAL mechanism from grounding G3 rather than booting a module and
// hoping loadDbOverrides() ran — an assertion that could pass vacuously.
// `override()` ignores unknown config modules, which is the single property that
// makes a `$`-prefixed app_configs id inert. If this breaks, D6 is invalid and
// the stamp is leaking into runtime config.
test('override() ignores the $deployment key entirely (grounding G3)', t => {
  const config = { auth: { allowSignup: true } } as unknown as AppConfig;

  override(config, {
    [DEPLOYMENT_STAMP_ID]: { deploymentId: 'prod-a' },
  } as unknown as DeepPartial<AppConfig>);

  t.false(
    DEPLOYMENT_STAMP_ID in (config as unknown as Record<string, unknown>)
  );
  t.deepEqual(config, { auth: { allowSignup: true } } as unknown as AppConfig);
});

test('a real loadDbOverrides pass leaves the stamp out of the config tree', async t => {
  await writeStamp(db, stamp('prod-a'));

  // Mirrors ServerService.loadDbOverrides(): read every row, set() it by id,
  // then hand the result to override().
  const rows = await db.appConfig.findMany();
  t.true(
    rows.some(row => row.id === DEPLOYMENT_STAMP_ID),
    'stamp row must exist'
  );

  const overrides: Record<string, unknown> = {};
  for (const row of rows) {
    set(overrides, row.id, row.value);
  }
  const config = { auth: { allowSignup: true } } as unknown as AppConfig;
  override(config, overrides as DeepPartial<AppConfig>);

  t.false(
    DEPLOYMENT_STAMP_ID in (config as unknown as Record<string, unknown>)
  );
});

test('evaluateIdentity classifies absent, unchecked, match and mismatch', t => {
  t.is(evaluateIdentity(null, 'prod-a').kind, 'absent');
  t.is(evaluateIdentity(stamp('prod-a'), null).kind, 'unchecked');
  t.is(evaluateIdentity(stamp('prod-a'), 'prod-a').kind, 'match');
  t.is(evaluateIdentity(stamp('prod-a'), 'prod-b').kind, 'mismatch');
});

// Important fix: a corrupt stamp must refuse regardless of whether an
// AFFINE_DEPLOYMENT_ID is configured — we cannot confirm whose database this
// is, and the row is evidence of a prior adoption we must not clobber.
test('evaluateIdentity reports corrupt regardless of the configured id', t => {
  t.is(evaluateIdentity(null, null, true).kind, 'corrupt');
  t.is(evaluateIdentity(null, 'prod-a', true).kind, 'corrupt');
});
