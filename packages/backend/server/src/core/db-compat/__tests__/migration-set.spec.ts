import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import test from 'ava';

import { loadMigrationSet, resolveMigrationsDir } from '../migration-set';

const tempDirs: string[] = [];

const tempDir = (prefix: string) => {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
};

test.after.always('remove temp directories', () => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

const fixture = () => {
  const root = tempDir('db-compat-');
  const dir = join(root, 'migrations');
  mkdirSync(join(dir, '20240101000000_a'), { recursive: true });
  mkdirSync(join(dir, '20240102000000_b'), { recursive: true });
  writeFileSync(
    join(dir, '20240101000000_a', 'migration.sql'),
    'CREATE TABLE "a" ();'
  );
  writeFileSync(
    join(dir, '20240102000000_b', 'migration.sql'),
    'DROP TABLE "a";'
  );
  writeFileSync(join(dir, 'migration_lock.toml'), 'provider = "postgresql"');
  return { root, dir };
};

test('resolveMigrationsDir finds migrations/ under the given root', t => {
  const { root, dir } = fixture();
  t.is(resolveMigrationsDir([root]), dir);
});

test('resolveMigrationsDir returns null when no candidate has one', t => {
  t.is(resolveMigrationsDir([tempDir('empty-')]), null);
});

test('resolveMigrationsDir rejects a migrations/ directory without migration_lock.toml (issue 5)', t => {
  const root = tempDir('db-compat-nolock-');
  mkdirSync(join(root, 'migrations', '20240101000000_a'), {
    recursive: true,
  });
  writeFileSync(
    join(root, 'migrations', '20240101000000_a', 'migration.sql'),
    'CREATE TABLE "a" ();'
  );
  t.is(resolveMigrationsDir([root]), null);
});

test('loadMigrationSet lists directories only, sorted, skipping the lock file', t => {
  const { dir } = fixture();
  const set = loadMigrationSet(dir);
  t.truthy(set);
  t.deepEqual(set!.names, ['20240101000000_a', '20240102000000_b']);
});

test('loadMigrationSet reads migration.sql by name', t => {
  const { dir } = fixture();
  t.is(loadMigrationSet(dir)!.sql('20240102000000_b'), 'DROP TABLE "a";');
});

test('loadMigrationSet returns null for an unknown name rather than throwing', t => {
  const { dir } = fixture();
  t.is(loadMigrationSet(dir)!.sql('nope'), null);
});

// This test exists to prove `resolveMigrationsDir()` finds the REAL directory
// from a test's working directory — the count was incidental, and asserting it
// meant an upstream merge that adds a migration broke this file for no reason.
// Assert the shape instead, which is what "we found the right directory" means.
test('the real repository migrations directory resolves and looks like one', t => {
  const dir = resolveMigrationsDir();
  t.truthy(dir, 'resolveMigrationsDir() found no candidate');

  const set = loadMigrationSet(dir!);
  t.truthy(set);
  t.true(set!.names.length > 0, 'the real corpus should not be empty');

  // Prisma names a migration <14-digit timestamp><separator><slug>. Note the
  // separator is not always `_`: 20250303105325-notification uses a hyphen.
  const misshapen = set!.names.filter(n => !/^\d{14}[_-]\S+$/.test(n));
  t.deepEqual(misshapen, [], 'every entry should be a prisma migration name');

  // `names` is documented as prisma's own apply order, so it must be sorted.
  t.deepEqual(set!.names, [...set!.names].sort());

  // The discriminator the resolver requires, so this really is a prisma dir.
  t.true(existsSync(join(dir!, 'migration_lock.toml')));

  // Every entry is readable — a directory whose migration.sql is missing would
  // return null and be gated as unreadable, which should not be true of ours.
  const unreadable = set!.names.filter(n => set!.sql(n) === null);
  t.deepEqual(
    unreadable,
    [],
    'every migration should have a readable sql file'
  );
});
