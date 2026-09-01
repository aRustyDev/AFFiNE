import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import test from 'ava';

import { classifyDdl, scrubSql, splitStatements } from '../classify';

test('additive DDL is EXPAND', t => {
  const { tier, hits } = classifyDdl(
    'CREATE TABLE "foo" ("id" TEXT NOT NULL);'
  );
  t.is(tier, 'EXPAND');
  t.deepEqual(hits, []);
});

test('DROP TABLE is BLOCKING', t => {
  const { tier, hits } = classifyDdl('DROP TABLE "foo";');
  t.is(tier, 'BLOCKING');
  t.is(hits.length, 1);
  t.is(hits[0].rule, 'drop-table');
  t.is(hits[0].line, 1);
});

test('DROP CONSTRAINT alone is DESTRUCTIVE, never BLOCKING', t => {
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "foo" DROP CONSTRAINT "foo_bar_fkey";'
  );
  t.is(tier, 'DESTRUCTIVE');
  t.is(hits[0].rule, 'drop-constraint');
});

test('a BLOCKING hit wins over a DESTRUCTIVE one', t => {
  const { tier } = classifyDdl(
    'ALTER TABLE "foo" DROP CONSTRAINT "c";\nALTER TABLE "foo" DROP COLUMN "bar";'
  );
  t.is(tier, 'BLOCKING');
});

test('SET NOT NULL split across lines is still caught (G2c)', t => {
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "foo" ALTER COLUMN "bar"\n  SET NOT NULL;'
  );
  t.is(tier, 'BLOCKING');
  t.is(hits[0].rule, 'set-not-null');
});

test('DDL inside a $$ function body is ignored (G2b)', t => {
  const sql = [
    'CREATE OR REPLACE FUNCTION purge() RETURNS void AS $$',
    'BEGIN',
    '  DELETE FROM "audit";',
    '  DROP TABLE "scratch";',
    'END;',
    '$$ LANGUAGE plpgsql;',
  ].join('\n');
  t.is(classifyDdl(sql).tier, 'EXPAND');
});

test('DDL inside a tagged dollar body is ignored', t => {
  const sql =
    'CREATE FUNCTION f() RETURNS void AS $body$ DROP TABLE "x"; $body$ LANGUAGE plpgsql;';
  t.is(classifyDdl(sql).tier, 'EXPAND');
});

test('commented-out DDL is ignored', t => {
  t.is(
    classifyDdl('-- DROP TABLE "foo";\nCREATE TABLE "foo" ("id" TEXT);').tier,
    'EXPAND'
  );
  t.is(
    classifyDdl('/* DROP TABLE "foo"; */ CREATE TABLE "foo" ("id" TEXT);').tier,
    'EXPAND'
  );
});

test('scrubSql preserves line count', t => {
  const sql = 'a\n-- b\n/* c\nd */\ne';
  t.is(scrubSql(sql).split('\n').length, sql.split('\n').length);
});

test('splitStatements reports the line each statement starts on', t => {
  const stmts = splitStatements('CREATE TABLE "a" ();\n\nDROP TABLE "b";');
  t.is(stmts.length, 2);
  t.is(stmts[0].line, 1);
  t.is(stmts[1].line, 3);
});

// --- corpus anchors and totals, measured in grounding G2a -------------------
// These are the regression fixtures the tiering exists for. Do not soften them
// to make a rule-set change pass; if a number here moves, re-measure and say so.

const MIGRATIONS_DIR = join(import.meta.dirname, '../../../../migrations');

const corpus = () =>
  readdirSync(MIGRATIONS_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .sort();

test('corpus tiers exactly as measured: 18 / 14 / 85 of 117', t => {
  const counts = { BLOCKING: 0, DESTRUCTIVE: 0, EXPAND: 0 };
  for (const name of corpus()) {
    const sql = readFileSync(
      join(MIGRATIONS_DIR, name, 'migration.sql'),
      'utf8'
    );
    counts[classifyDdl(sql).tier]++;
  }
  t.is(counts.BLOCKING + counts.DESTRUCTIVE + counts.EXPAND, 117);
  t.deepEqual(counts, { BLOCKING: 18, DESTRUCTIVE: 14, EXPAND: 85 });
});

test('anchor: drop_legacy_permission_and_subscription is BLOCKING', t => {
  const sql = readFileSync(
    join(
      MIGRATIONS_DIR,
      '20260714000001_drop_legacy_permission_and_subscription',
      'migration.sql'
    ),
    'utf8'
  );
  t.is(classifyDdl(sql).tier, 'BLOCKING');
});

test('anchor: converge_copilot_runtime is DESTRUCTIVE, not BLOCKING', t => {
  const sql = readFileSync(
    join(
      MIGRATIONS_DIR,
      '20260803095500_converge_copilot_runtime',
      'migration.sql'
    ),
    'utf8'
  );
  const { tier, hits } = classifyDdl(sql);
  t.is(tier, 'DESTRUCTIVE');
  t.deepEqual([...new Set(hits.map(h => h.rule))], ['drop-constraint']);
});

test('anchor: function-body-only DDL stays EXPAND', t => {
  for (const name of [
    '20260512133700_workspace_runtime_states',
    '20260514000000_entitlement_quota_states',
  ]) {
    const sql = readFileSync(
      join(MIGRATIONS_DIR, name, 'migration.sql'),
      'utf8'
    );
    t.is(classifyDdl(sql).tier, 'EXPAND', name);
  }
});
