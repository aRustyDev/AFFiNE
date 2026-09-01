import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import test from 'ava';

import { loadMigrationSet, resolveMigrationsDir } from '../migration-set';

const fixture = () => {
  const root = mkdtempSync(join(tmpdir(), 'db-compat-'));
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
  t.is(resolveMigrationsDir([mkdtempSync(join(tmpdir(), 'empty-'))]), null);
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

test('loadMigrationSet returns empty sql for an unknown name rather than throwing', t => {
  const { dir } = fixture();
  t.is(loadMigrationSet(dir)!.sql('nope'), '');
});

test('the real repository migrations directory resolves and has 117 entries', t => {
  const dir = resolveMigrationsDir();
  t.truthy(dir);
  t.is(loadMigrationSet(dir!)!.names.length, 117);
});
