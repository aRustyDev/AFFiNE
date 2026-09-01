import { PrismaClient } from '@prisma/client';
import test from 'ava';

import { readDbState } from '../db-state';

const db = new PrismaClient();

test.before(async () => {
  await db.$connect();
});

test.after.always(async () => {
  await db.$disconnect();
});

test('readDbState reports the real migration history', async t => {
  const state = await readDbState(db);
  t.true(state.hasMigrationsTable);
  t.true(state.rows.length > 0);
  t.true(state.applied.length > 0);
  t.deepEqual(state.failed, []);
});

test('readDbState surfaces a missing table as hasMigrationsTable false, not a throw', async t => {
  // Bind an EMPTY schema via the connection URL's `?schema=`, not via
  // `SET search_path`. Prisma pools connections, so a bare SET may land on a
  // different session than the query that follows it — a flaky test. `?schema=`
  // is applied per connection, so it holds for every query this client makes.
  const SCRATCH = 'db_compat_scratch';
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${SCRATCH}"`);

  const url = new URL(process.env.DATABASE_URL as string);
  url.searchParams.set('schema', SCRATCH);
  const scratch = new PrismaClient({
    datasources: { db: { url: url.toString() } },
  });

  try {
    const state = await readDbState(scratch);
    // Neither _prisma_migrations nor users exists in the empty schema, so both
    // reads must degrade rather than throw.
    t.false(state.hasMigrationsTable);
    t.deepEqual(state.rows, []);
    t.false(state.populated);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCRATCH}" CASCADE`);
  }
});

test('readDbState reports populated from the user count', async t => {
  const state = await readDbState(db);
  const users = await db.user.count();
  t.is(state.populated, users > 0);
});
