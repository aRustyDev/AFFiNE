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
  t.true(report.rollbackPossible);
});

test('UNREADABLE when the migration set is missing', t => {
  const report = buildReport({ ...base, migrations: null });
  t.is(report.verdict, 'UNREADABLE');
  t.is(report.rollbackPossible, null);
});

test('VIRGIN when there is no migrations table and no data', t => {
  const report = buildReport({
    ...base,
    hasMigrationsTable: false,
    appliedRows: [],
    populated: false,
  });
  t.is(report.verdict, 'VIRGIN');
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
