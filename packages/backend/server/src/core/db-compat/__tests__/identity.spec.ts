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

test('readStamp returns null when absent', async t => {
  t.is(await readStamp(db), null);
});

test('writeStamp then readStamp round-trips', async t => {
  await writeStamp(db, stamp('prod-a'));
  const read = await readStamp(db);
  t.is(read?.deploymentId, 'prod-a');
  t.is(read?.adoptionMode, 'explicit');
});

test('writeStamp is an upsert, not a duplicate-key error', async t => {
  await writeStamp(db, stamp('prod-a'));
  await writeStamp(db, { ...stamp('prod-a'), adoptionMode: 'implicit' });
  t.is((await readStamp(db))?.adoptionMode, 'implicit');
  t.is(await db.appConfig.count({ where: { id: DEPLOYMENT_STAMP_ID } }), 1);
});

test('readStamp returns null rather than throwing on a malformed row', async t => {
  await db.appConfig.create({
    data: { id: DEPLOYMENT_STAMP_ID, value: { nope: true } },
  });
  t.is(await readStamp(db), null);
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
