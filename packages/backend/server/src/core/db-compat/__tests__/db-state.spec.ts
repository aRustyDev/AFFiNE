import { PrismaClient } from '@prisma/client';
import test from 'ava';

import { readDbState } from '../db-state';

const db = new PrismaClient();

function requireDatabaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) {
    throw new Error(
      'DATABASE_URL must be set to run db-state.spec.ts against a real Postgres instance'
    );
  }
  return url;
}

function scratchClient(schema: string): PrismaClient {
  const url = new URL(requireDatabaseUrl());
  url.searchParams.set('schema', schema);
  return new PrismaClient({ datasources: { db: { url: url.toString() } } });
}

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
  t.true(state.rows.some(row => !row.rolledBackAt));
  t.deepEqual(
    state.rows.filter(row => !row.finishedAt && !row.rolledBackAt),
    []
  );
});

test('readDbState surfaces a missing table as hasMigrationsTable false, not a throw', async t => {
  // Bind an EMPTY schema via the connection URL's `?schema=`, not via
  // `SET search_path`. Prisma pools connections, so a bare SET may land on a
  // different session than the query that follows it — a flaky test. `?schema=`
  // is applied per connection, so it holds for every query this client makes.
  const SCRATCH = 'db_compat_scratch';
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${SCRATCH}"`);
  const scratch = scratchClient(SCRATCH);

  try {
    const state = await readDbState(scratch);
    // Neither _prisma_migrations nor users exists in the empty schema, so both
    // reads must degrade rather than throw. `populated` is `null` here
    // (undetermined) — this schema has nothing at all, not "determined to
    // have zero users".
    t.false(state.hasMigrationsTable);
    t.deepEqual(state.rows, []);
    t.is(state.populated, null);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCRATCH}" CASCADE`);
  }
});

test('readDbState reports populated true when the users table has rows', async t => {
  const SCRATCH = 'db_compat_scratch_populated';
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${SCRATCH}"`);
  // Only `users` (the `@@map`-ed table for the User model) needs to exist for
  // `db.user.count()` to succeed — a plain count with no filter never
  // references specific columns, so a minimal one-column table is enough.
  await db.$executeRawUnsafe(
    `CREATE TABLE "${SCRATCH}"."users" (id text PRIMARY KEY)`
  );
  await db.$executeRawUnsafe(
    `INSERT INTO "${SCRATCH}"."users" (id) VALUES ('scratch-user-1')`
  );
  const scratch = scratchClient(SCRATCH);

  try {
    const state = await readDbState(scratch);
    t.is(state.populated, true);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCRATCH}" CASCADE`);
  }
});

test('readDbState reports populated null when migration history exists but the users table is missing', async t => {
  // The restore/DR scenario affine-tc6 exists for: a partially-restored
  // database that recorded migration history but is missing a core table.
  const SCRATCH = 'db_compat_scratch_partial';
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${SCRATCH}"`);
  await db.$executeRawUnsafe(`
    CREATE TABLE "${SCRATCH}"."_prisma_migrations" (
      id varchar(36) PRIMARY KEY,
      checksum varchar(64) NOT NULL,
      finished_at timestamptz,
      migration_name varchar(255) NOT NULL,
      logs text,
      rolled_back_at timestamptz,
      started_at timestamptz NOT NULL DEFAULT now(),
      applied_steps_count integer NOT NULL DEFAULT 0
    )
  `);
  await db.$executeRawUnsafe(`
    INSERT INTO "${SCRATCH}"."_prisma_migrations"
      (id, checksum, finished_at, migration_name, started_at, applied_steps_count)
    VALUES ('11111111-1111-1111-1111-111111111111', 'checksum', now(), 'm1', now(), 1)
  `);
  const scratch = scratchClient(SCRATCH);

  try {
    const state = await readDbState(scratch);
    t.true(state.hasMigrationsTable);
    t.true(state.rows.length > 0);
    t.is(state.populated, null);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${SCRATCH}" CASCADE`);
  }
});
