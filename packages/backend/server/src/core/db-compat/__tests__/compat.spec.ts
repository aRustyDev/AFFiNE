import test from 'ava';

import { buildReport, type CompatInput } from '../compat';

const base: CompatInput = {
  migrations: {
    dir: '/app/migrations',
    names: ['m1', 'm2'],
    sql: (name: string) =>
      name === 'm2' ? 'DROP TABLE "x";' : 'CREATE TABLE "x" ();',
  },
  hasMigrationsTable: true,
  appliedRows: [
    { name: 'm1', finishedAt: new Date(), rolledBackAt: null },
    { name: 'm2', finishedAt: new Date(), rolledBackAt: null },
  ],
  populated: true,
  stamp: null,
  configuredDeploymentId: null,
};

test('EQUAL when applied matches known', t => {
  const report = buildReport(base);
  t.is(report.verdict, 'EQUAL');
  t.deepEqual(report.pending, []);
  // Nothing is pending, so there is nothing to classify — this engine never
  // examines already-applied migrations, so "rollback is possible" would be
  // an assertion on evidence it doesn't have.
  t.is(report.rollbackPossible, null);
});

test('UNREADABLE when the migration set is missing', t => {
  const report = buildReport({ ...base, migrations: null });
  t.is(report.verdict, 'UNREADABLE');
  t.is(report.rollbackPossible, null);
});

test('UNREADABLE outranks MIGRATION_FAILED', t => {
  const report = buildReport({
    ...base,
    migrations: null,
    appliedRows: [{ name: 'm1', finishedAt: null, rolledBackAt: null }],
  });
  t.is(report.verdict, 'UNREADABLE');
});

test('VIRGIN when there is no migrations table and no data', t => {
  const report = buildReport({
    ...base,
    hasMigrationsTable: false,
    appliedRows: [],
    populated: false,
  });
  t.is(report.verdict, 'VIRGIN');
  // The fixture's m2 is `DROP TABLE`, so a fresh install would apply a
  // BLOCKING migration on its way up — VIRGIN must report the computed
  // answer from `pending`, not throw it away as null.
  t.false(report.rollbackPossible);
  t.is(report.reason, 'no migration history and no data — a fresh install');
});

test('VIRGIN still holds when population could not be determined', t => {
  const report = buildReport({
    ...base,
    hasMigrationsTable: false,
    appliedRows: [],
    populated: null,
  });
  t.is(report.verdict, 'VIRGIN');
  // populated: null means "never checked", not "checked and found empty" —
  // the reason must not claim "no data" for a state that was never examined.
  t.is(
    report.reason,
    'no migration history and no users table — a fresh install'
  );
});

test('SCHEMA_INCOMPLETE when migration history exists but population could not be determined', t => {
  const report = buildReport({
    ...base,
    // Zero applied rows on purpose: this branch must not claim migrations
    // were recorded as applied — it is reachable with none, e.g. a table
    // left by an aborted setup, or a history that was entirely rolled back.
    appliedRows: [],
    populated: null,
  });
  t.is(report.verdict, 'SCHEMA_INCOMPLETE');
  t.is(report.rollbackPossible, null);
  t.is(
    report.reason,
    'the migrations table is present but the users table is absent, so this database is inconsistent'
  );
});

test('DB_BEHIND lists pending migrations with tiers', t => {
  const report = buildReport({
    ...base,
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.deepEqual(
    report.pending.map(p => [p.name, p.tier]),
    [['m2', 'BLOCKING']]
  );
  t.false(report.rollbackPossible);
});

test('DB_BEHIND with only additive pending keeps rollback possible', t => {
  const report = buildReport({
    ...base,
    migrations: { ...base.migrations!, sql: () => 'CREATE TABLE "y" ();' },
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.true(report.rollbackPossible);
});

test('an UNREADABLE pending migration fails closed, not open', t => {
  const report = buildReport({
    ...base,
    migrations: { ...base.migrations!, sql: () => null },
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.is(report.pending[0].tier, 'BLOCKING');
  t.is(report.pending[0].hits[0].rule, 'unreadable-migration');
  // The whole point: a migration we cannot read must never report as safe.
  t.false(report.rollbackPossible);
});

test('a migration.sql read that throws fails closed and does not crash buildReport', t => {
  const report = buildReport({
    ...base,
    migrations: {
      ...base.migrations!,
      sql: () => {
        throw new Error('EACCES: permission denied');
      },
    },
    appliedRows: [{ name: 'm1', finishedAt: new Date(), rolledBackAt: null }],
  });
  t.is(report.verdict, 'DB_BEHIND');
  t.is(report.pending[0].tier, 'BLOCKING');
  t.is(report.pending[0].hits[0].rule, 'unreadable-migration');
  t.false(report.rollbackPossible);
});

test('DB_AHEAD when the database has migrations this binary lacks', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      ...base.appliedRows,
      { name: 'm3', finishedAt: new Date(), rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'DB_AHEAD');
  t.deepEqual(report.ahead, ['m3']);
});

test('DIVERGED when each side has what the other lacks', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      { name: 'm1', finishedAt: new Date(), rolledBackAt: null },
      { name: 'mX', finishedAt: new Date(), rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'DIVERGED');
  t.deepEqual(report.ahead, ['mX']);
  t.deepEqual(
    report.pending.map(p => p.name),
    ['m2']
  );
});

test('a rolled-back row does not count as applied and does not make the DB ahead', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      ...base.appliedRows,
      { name: 'm3', finishedAt: null, rolledBackAt: new Date() },
    ],
  });
  t.is(report.verdict, 'EQUAL');
  t.deepEqual(report.ahead, []);
});

test('MIGRATION_FAILED when a row is unfinished and not rolled back', t => {
  const report = buildReport({
    ...base,
    appliedRows: [
      { name: 'm1', finishedAt: new Date(), rolledBackAt: null },
      { name: 'm2', finishedAt: null, rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'MIGRATION_FAILED');
  t.deepEqual(report.failed, ['m2']);
});

test('IDENTITY_MISMATCH when the stamp names another deployment', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: 'prod-a',
    stamp: {
      deploymentId: 'prod-b',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'explicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
  });
  t.is(report.verdict, 'IDENTITY_MISMATCH');
  t.is(report.identity.kind, 'mismatch');
});

test('a matching stamp is EQUAL and reports identity match', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: 'prod-a',
    stamp: {
      deploymentId: 'prod-a',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'explicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
  });
  t.is(report.verdict, 'EQUAL');
  t.is(report.identity.kind, 'match');
});

test('a stamp with no configured id is unchecked, not a mismatch', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: null,
    stamp: {
      deploymentId: 'minted-uuid',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'implicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
  });
  t.is(report.verdict, 'EQUAL');
  t.is(report.identity.kind, 'unchecked');
});

// Important fix: previously, a corrupt stamp row read as `stamp: null` from
// `readStamp`, which collapsed into `identity.kind === 'absent'` — the
// adoption gate would then run and overwrite the corrupt row. That fails
// OPEN and destroys evidence of a prior adoption. `compat.ts`'s own
// philosophy is the opposite: an unreadable migration is coerced to
// BLOCKING, not treated as safely absent. A corrupt stamp must refuse the
// same way, and must do so even with no configured deployment id — we
// cannot confirm whose database this is, so we must not clobber it.
test('a corrupt stamp is IDENTITY_MISMATCH, even with no configured id', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: null,
    stamp: null,
    stampCorrupt: true,
  });
  t.is(report.verdict, 'IDENTITY_MISMATCH');
  t.is(report.identity.kind, 'corrupt');
});

test('identity mismatch outranks DB_AHEAD — the wrong database is the better message', t => {
  const report = buildReport({
    ...base,
    configuredDeploymentId: 'prod-a',
    stamp: {
      deploymentId: 'prod-b',
      adoptedAt: '2026-01-01T00:00:00.000Z',
      adoptionMode: 'explicit',
      adoptedBy: { version: '0.27.0', buildSha: 'abc' },
    },
    appliedRows: [
      ...base.appliedRows,
      { name: 'm9', finishedAt: new Date(), rolledBackAt: null },
    ],
  });
  t.is(report.verdict, 'IDENTITY_MISMATCH');
});
