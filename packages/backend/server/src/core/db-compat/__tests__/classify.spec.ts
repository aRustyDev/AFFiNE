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

test('a dollar tag containing digits is recognised (issue 4)', t => {
  const sql =
    'CREATE FUNCTION f() RETURNS void AS $b1$ DROP TABLE x; $b1$ LANGUAGE plpgsql;';
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

test('scrubSql preserves line count across a multi-line dollar body', t => {
  const sql = [
    'CREATE FUNCTION f() RETURNS void AS $$',
    'BEGIN',
    '  DROP TABLE x;',
    'END;',
    '$$ LANGUAGE plpgsql;',
  ].join('\n');
  t.is(scrubSql(sql).split('\n').length, sql.split('\n').length);
});

test('splitStatements reports the line each statement starts on', t => {
  const stmts = splitStatements('CREATE TABLE "a" ();\n\nDROP TABLE "b";');
  t.is(stmts.length, 2);
  t.is(stmts[0].line, 1);
  t.is(stmts[1].line, 3);
});

// --- issue 1: rename-table must be anchored to ALTER TABLE ------------------

test('ALTER TABLE RENAME TO is rename-table', t => {
  const { tier, hits } = classifyDdl('ALTER TABLE "foo" RENAME TO "bar";');
  t.is(tier, 'BLOCKING');
  t.is(hits[0].rule, 'rename-table');
});

test('ALTER INDEX RENAME TO is not rename-table (issue 1)', t => {
  const { tier, hits } = classifyDdl('ALTER INDEX "i" RENAME TO "j";');
  t.is(tier, 'EXPAND');
  t.deepEqual(hits, []);
});

test('RENAME COLUMN is rename-column', t => {
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "foo" RENAME COLUMN "a" TO "b";'
  );
  t.is(tier, 'BLOCKING');
  t.is(hits[0].rule, 'rename-column');
});

// --- issue 6: truncate must be anchored to the start of the statement -------

test('TRUNCATE is destructive', t => {
  const { tier, hits } = classifyDdl('TRUNCATE "foo";');
  t.is(tier, 'DESTRUCTIVE');
  t.is(hits[0].rule, 'truncate');
});

test('a quoted identifier containing "truncate" does not trigger the rule (issue 6)', t => {
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "t" ADD COLUMN "truncate" BOOLEAN;'
  );
  t.is(tier, 'EXPAND');
  t.deepEqual(hits, []);
});

// --- issue 2: string / identifier scanning must not derail on escapes ------

test('a DROP keyword inside a string literal is scrubbed, not classified', t => {
  t.is(classifyDdl("INSERT INTO t VALUES ('DROP TABLE zz');").tier, 'EXPAND');
});

test('a backslash escape inside a string literal does not derail the scanner (issue 2a)', t => {
  const { tier, hits } = classifyDdl(
    "INSERT INTO t VALUES (E'\\''); DROP TABLE b;"
  );
  t.is(tier, 'BLOCKING');
  t.true(hits.some(h => h.rule === 'drop-table'));
});

test('a doubled single-quote escape does not derail the scanner (issue 2a)', t => {
  const { tier } = classifyDdl(
    "INSERT INTO t VALUES ('it''s fine'); DROP TABLE b;"
  );
  t.is(tier, 'BLOCKING');
});

test('an apostrophe inside a double-quoted identifier does not derail the scanner (issue 2b)', t => {
  // The stray apostrophe inside the identifier must not be mistaken for the
  // start of a string literal — if it were, everything after it (including
  // the DROP TABLE) would be scanned-for-a-closing-quote and blanked away.
  const { tier, hits } = classifyDdl(
    'ALTER TABLE "user\'s" ADD COLUMN "a" TEXT; DROP TABLE b;'
  );
  t.is(tier, 'BLOCKING');
  t.true(hits.some(h => h.rule === 'drop-table'));
});

// --- issue 2c: unparseable SQL must fail closed to BLOCKING -----------------

test('an unterminated string literal is unparseable and fails closed (issue 2c)', t => {
  const { tier, hits, unterminated } = classifyDdl(
    "SELECT * FROM t WHERE x = 'abc"
  );
  t.true(unterminated);
  t.is(tier, 'BLOCKING');
  t.true(hits.some(h => h.rule === 'unparseable'));
});

test('an unterminated double-quoted identifier is unparseable and fails closed (issue 2c)', t => {
  const { tier, unterminated } = classifyDdl(
    'ALTER TABLE "foo ADD COLUMN x TEXT;'
  );
  t.true(unterminated);
  t.is(tier, 'BLOCKING');
});

test('an unterminated block comment is unparseable and fails closed (issue 2c)', t => {
  const { tier, unterminated } = classifyDdl(
    '/* never closes\nCREATE TABLE a ();'
  );
  t.true(unterminated);
  t.is(tier, 'BLOCKING');
});

test('an unterminated dollar-quoted body is unparseable and fails closed (issue 2c)', t => {
  const { tier, unterminated } = classifyDdl(
    'CREATE FUNCTION f() RETURNS void AS $$ BEGIN NULL; END;'
  );
  t.true(unterminated);
  t.is(tier, 'BLOCKING');
});

test('well-formed SQL is not flagged unterminated', t => {
  const { unterminated } = classifyDdl('CREATE TABLE "foo" ("id" TEXT);');
  t.false(unterminated);
});

test('a trailing backslash in a plain (non-E-prefixed) literal is not an escape', t => {
  // standard_conforming_strings = on (the default since Postgres 9.1) means a
  // backslash in a plain '...' literal is an ordinary character, not an
  // escape — so 'a\' is already a complete, terminated string. Only an
  // E-prefixed literal (E'...') honours backslash escapes.
  const { tier, hits, unterminated } = classifyDdl(
    "INSERT INTO t VALUES ('a\\'); DROP TABLE b;"
  );
  t.false(unterminated);
  t.is(tier, 'BLOCKING');
  t.true(hits.some(h => h.rule === 'drop-table'));
  t.false(hits.some(h => h.rule === 'unparseable'));
});

test('a path-shaped default with a trailing backslash is not an escape', t => {
  const { unterminated } = classifyDdl(
    "ALTER TABLE t ALTER COLUMN p SET DEFAULT 'C:\\';"
  );
  t.false(unterminated);
});

test('unterminated always implies BLOCKING (issue 2 hardening)', t => {
  const unterminatedCases = [
    "SELECT * FROM t WHERE x = 'abc",
    'ALTER TABLE "foo ADD COLUMN x TEXT;',
    '/* never closes\nCREATE TABLE a ();',
    'CREATE FUNCTION f() RETURNS void AS $$ BEGIN NULL; END;',
  ];
  for (const sql of unterminatedCases) {
    const { tier, unterminated } = classifyDdl(sql);
    t.true(unterminated, sql);
    t.is(tier, 'BLOCKING', sql);
  }
});

// --- issue 7: hit statement text must not be truncated ----------------------

test('a hit statement is not truncated even when long (issue 7)', t => {
  const longIdentifier = 'a'.repeat(200);
  const sql = `ALTER TABLE "foo" ALTER COLUMN "${longIdentifier}" TYPE INTEGER;`;
  const { hits } = classifyDdl(sql);
  const hit = hits.find(h => h.rule === 'retype-column');
  t.truthy(hit);
  t.true(hit!.statement.includes('TYPE INTEGER'));
});

// --- corpus anchors and totals, measured in grounding G2a -------------------
// These are the regression fixtures the tiering exists for. Do not soften them
// to make a rule-set change pass; if a number here moves, re-measure and say so.
//
// 17/14/86 as of the quoted-identifier scrub (code review round on
// affine-tc6.1). The earlier 18/14/85 baseline included a false-positive
// BLOCKING on 20250203142831_standardize_features, where `retype-column`
// (`/\bALTER\s+COLUMN\b.*?\bTYPE\b/i`) matched the quoted column name "type"
// instead of a real TYPE keyword — that migration only adds columns, sets
// defaults, and creates indexes, so EXPAND is correct. Scrubbing double-quoted
// identifiers (issue 2b) removed the false positive; this is a correction to
// the measured evidence, not a relaxation of it.

const MIGRATIONS_DIR = join(import.meta.dirname, '../../../../migrations');

const corpus = () =>
  readdirSync(MIGRATIONS_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .sort();

test('corpus tiers exactly as measured: 17 / 14 / 86 of 117', t => {
  const counts = { BLOCKING: 0, DESTRUCTIVE: 0, EXPAND: 0 };
  for (const name of corpus()) {
    const sql = readFileSync(
      join(MIGRATIONS_DIR, name, 'migration.sql'),
      'utf8'
    );
    counts[classifyDdl(sql).tier]++;
  }
  t.deepEqual(counts, { BLOCKING: 17, DESTRUCTIVE: 14, EXPAND: 86 });
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
