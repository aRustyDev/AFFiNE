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

// --- corpus assertions: INVARIANTS, not a snapshot -------------------------
//
// These protect the RULE SET. They deliberately do NOT assert the corpus size or
// the exact tier distribution, because upstream adds migrations on every merge
// and an exact count would fail on each one — uninformatively ("expected 117,
// got 118" says nothing about whether the classifier is still correct) and with
// the only sensible remedy being to edit the number. An assertion that must be
// edited routinely trains people to edit it without thinking, which is worse
// than no assertion.
//
// New CONTENT is covered elsewhere: merge-checklist step 2 in
// scripts/woven-patch-manifest.md runs `db status` over the incoming migrations.
// That is a different job from protecting the rules, and conflating the two is
// what produced the brittle version of this file.
//
// The measured distribution as of 2026-09-01 — 17 BLOCKING / 14 DESTRUCTIVE /
// 86 EXPAND of 117 — is recorded in findings/grounding.md G2a as a dated data
// point. The evidence trail lives there; the brittleness does not live here.

const MIGRATIONS_DIR = join(import.meta.dirname, '../../../../migrations');

const corpus = () =>
  readdirSync(MIGRATIONS_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .sort();

const classifyCorpus = () => {
  const counts = { BLOCKING: 0, DESTRUCTIVE: 0, EXPAND: 0 };
  const firedRules = new Set<string>();
  const names = corpus();

  for (const name of names) {
    const { tier, hits } = classifyDdl(
      readFileSync(join(MIGRATIONS_DIR, name, 'migration.sql'), 'utf8')
    );
    counts[tier]++;
    for (const hit of hits) {
      firedRules.add(hit.rule);
    }
  }

  return { counts, firedRules, total: names.length };
};

test('every migration is accounted for in exactly one tier', t => {
  const { counts, total } = classifyCorpus();
  t.is(
    counts.BLOCKING + counts.DESTRUCTIVE + counts.EXPAND,
    total,
    'a migration that classified as nothing means classifyDdl returned an ' +
      'unexpected tier or threw'
  );
  t.true(total > 0, 'the corpus should not be empty');
});

// Floors, not equalities. Prisma migration directories are append-only —
// applied migrations are immutable history — so a tier's population can only
// grow as upstream merges land. `>=` is therefore sound AND stable, and it
// still catches the regression that matters: a rule silently stopping firing.
//
// Bumping a floor UP is a safe, optional tightening. That asymmetry is the
// whole point: nothing here ever *has* to be edited to make an unrelated
// upstream merge pass.
//
// If one of these ever fails, the corpus shrank — upstream squashed migrations,
// or a rule regressed. Both are worth stopping for.
const FLOOR_BLOCKING = 17;
const FLOOR_DESTRUCTIVE = 14;

test('the corpus still yields at least the measured floor per gating tier', t => {
  const { counts } = classifyCorpus();
  t.true(
    counts.BLOCKING >= FLOOR_BLOCKING,
    `BLOCKING fell to ${counts.BLOCKING}, below the measured floor of ${FLOOR_BLOCKING}`
  );
  t.true(
    counts.DESTRUCTIVE >= FLOOR_DESTRUCTIVE,
    `DESTRUCTIVE fell to ${counts.DESTRUCTIVE}, below the measured floor of ${FLOOR_DESTRUCTIVE}`
  );
  // No floor on EXPAND: it grows with every additive migration, so a floor
  // there asserts nothing about the rules.
});

// Stronger than any aggregate, and it does not decay as the corpus grows: an
// aggregate floor can stay satisfied while one specific rule dies. Only the
// seven rules with real corpus coverage are listed — `rename-table`,
// `rename-column` and `truncate` match nothing in this repo's history and are
// covered by the unit tests above instead. Measured 2026-09-01.
const RULES_WITH_CORPUS_COVERAGE = [
  'drop-constraint',
  'drop-index',
  'drop-table',
  'drop-column',
  'retype-column',
  'set-not-null',
  'delete-from',
] as const;

test('every rule with corpus coverage still fires on a real migration', t => {
  const { firedRules } = classifyCorpus();
  for (const rule of RULES_WITH_CORPUS_COVERAGE) {
    t.true(
      firedRules.has(rule),
      `rule "${rule}" no longer matches any migration in the corpus — it ` +
        `matched at least one when measured, so this is a detection regression`
    );
  }
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
