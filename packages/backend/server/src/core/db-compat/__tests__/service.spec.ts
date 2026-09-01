import test from 'ava';

import type { CompatReport } from '../compat';
import { decide } from '../service';

// `rollbackPossible: null` for EQUAL is the real contract (D16): the engine
// classifies only PENDING migrations, so it has no basis to claim rollback
// safety when nothing is pending.
const report = (over: Partial<CompatReport>): CompatReport => ({
  verdict: 'EQUAL',
  reason: 'ok',
  known: ['m1'],
  applied: ['m1'],
  pending: [],
  ahead: [],
  failed: [],
  rollbackPossible: null,
  populated: true,
  identity: { kind: 'absent' },
  ...over,
});

test('EQUAL with no stamp on a populated database auto-adopts implicitly', t => {
  const decision = decide(report({}), { adopt: false });
  t.true(decision.ok);
  t.is(decision.adopt, 'implicit');
});

test('VIRGIN adopts as a fresh install', t => {
  const decision = decide(report({ verdict: 'VIRGIN', populated: false }), {
    adopt: false,
  });
  t.true(decision.ok);
  t.is(decision.adopt, 'fresh-install');
});

test('DB_BEHIND with only additive pending auto-adopts', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'EXPAND', hits: [] }],
      rollbackPossible: true,
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, 'implicit');
});

test('DB_BEHIND with a BLOCKING pending migration REFUSES without the flag', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
    }),
    { adopt: false }
  );
  t.false(decision.ok);
  t.regex(decision.refusal!, /AFFINE_DB_ADOPT/);
});

test('the same case PROCEEDS with the flag, recorded as explicit', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
    }),
    { adopt: true }
  );
  t.true(decision.ok);
  t.is(decision.adopt, 'explicit');
});

test('an already-stamped database needs no adoption', t => {
  const decision = decide(
    report({
      identity: {
        kind: 'match',
        stamp: {
          deploymentId: 'prod-a',
          adoptedAt: '2026-01-01T00:00:00.000Z',
          adoptionMode: 'explicit',
          adoptedBy: { version: '0.27.0', buildSha: 'abc' },
        },
      },
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, null);
});

test('a BLOCKING pending migration on an ALREADY-adopted database does not re-gate', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
      identity: {
        kind: 'unchecked',
        stamp: {
          deploymentId: 'minted',
          adoptedAt: '2026-01-01T00:00:00.000Z',
          adoptionMode: 'implicit',
          adoptedBy: { version: '0.27.0', buildSha: 'abc' },
        },
      },
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, null);
});

// Every member of REFUSING_VERDICTS, including the ninth verdict added in T2.
// Keep this list in sync with `REFUSING_VERDICTS` in compat.ts — a verdict that
// refuses there but is missing here is an untested refusal path.
for (const verdict of [
  'DB_AHEAD',
  'DIVERGED',
  'IDENTITY_MISMATCH',
  'MIGRATION_FAILED',
  'SCHEMA_INCOMPLETE',
] as const) {
  test(`${verdict} always refuses, flag or not`, t => {
    t.false(decide(report({ verdict }), { adopt: false }).ok);
    t.false(decide(report({ verdict }), { adopt: true }).ok);
  });
}

test('UNREADABLE refuses when mutating and is reported as undetermined', t => {
  const decision = decide(
    report({ verdict: 'UNREADABLE', rollbackPossible: null }),
    { adopt: false }
  );
  t.false(decision.ok);
});
