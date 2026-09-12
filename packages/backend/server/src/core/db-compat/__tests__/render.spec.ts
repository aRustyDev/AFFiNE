import test from 'ava';

import type { CompatReport } from '../compat';
import type { DeploymentStamp } from '../identity';
import { renderReport } from '../render';

const stamp: DeploymentStamp = {
  deploymentId: 'deploy-123',
  adoptedAt: '2024-01-01T00:00:00.000Z',
  adoptionMode: 'implicit',
  adoptedBy: { version: '1.2.3', buildSha: 'abcdef0' },
};

// `rollbackPossible: null` on EQUAL is the real contract (D16) — the engine
// classifies only pending migrations, so with nothing pending it has no basis
// for a claim either way.
const report = (over: Partial<CompatReport>): CompatReport => ({
  verdict: 'EQUAL',
  reason: 'the database matches this binary',
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

test('renders the verdict and the rollback answer explicitly', t => {
  const text = renderReport(report({}));
  t.regex(text, /verdict:\s+EQUAL/);
  t.regex(text, /rollback after applying:\s+UNKNOWN/);
});

test('VIRGIN reports N/A rather than a computed IMPOSSIBLE', t => {
  // On a fresh install every migration is pending and some are BLOCKING, so the
  // computed answer is always false — but there is no prior deployment to roll
  // back to, and printing IMPOSSIBLE on the one unambiguously safe path is
  // alarming and useless.
  const text = renderReport(
    report({
      verdict: 'VIRGIN',
      populated: false,
      rollbackPossible: false,
      pending: [{ name: 'm1', tier: 'BLOCKING', hits: [] }],
    })
  );
  t.regex(text, /verdict:\s+VIRGIN/);
  t.regex(text, /rollback after applying:\s+N\/A/);
  t.notRegex(text, /IMPOSSIBLE/);
});

test('names each pending migration with its tier', t => {
  const text = renderReport(
    report({
      verdict: 'DB_BEHIND',
      rollbackPossible: false,
      pending: [
        {
          name: 'm2',
          tier: 'BLOCKING',
          hits: [
            {
              tier: 'BLOCKING',
              rule: 'drop-table',
              line: 3,
              statement: 'DROP TABLE "x"',
            },
          ],
        },
        { name: 'm3', tier: 'EXPAND', hits: [] },
      ],
    })
  );
  t.regex(text, /BLOCKING\s+m2/);
  t.regex(text, /EXPAND\s+m3/);
  t.regex(text, /drop-table/);
  t.regex(text, /rollback after applying:\s+IMPOSSIBLE/);
});

test('reports an undetermined rollback answer as UNKNOWN, never as POSSIBLE', t => {
  const text = renderReport(
    report({ verdict: 'DB_AHEAD', rollbackPossible: null, ahead: ['m9'] })
  );
  t.regex(text, /rollback after applying:\s+UNKNOWN/);
  t.notRegex(text, /POSSIBLE/);
});

test('an absent stamp renders as "not stamped"', t => {
  // The fixture's default identity is `{ kind: 'absent' }` — this exercises
  // that branch only. `unchecked`, `match` and `mismatch` (below) each need
  // their own test with a real `DeploymentStamp`, since they dereference
  // `identity.stamp.deploymentId` / `identity.configured`.
  const text = renderReport(report({}));
  t.regex(text, /identity:\s+not stamped/);
});

test('an unchecked stamp names its id and says AFFINE_DEPLOYMENT_ID is not set', t => {
  const text = renderReport(report({ identity: { kind: 'unchecked', stamp } }));
  t.regex(text, /identity:\s+deploy-123/);
  t.regex(text, /AFFINE_DEPLOYMENT_ID is not set/);
});

test('a matching stamp names its id and says it matches', t => {
  const text = renderReport(report({ identity: { kind: 'match', stamp } }));
  t.regex(text, /identity:\s+deploy-123/);
  t.regex(text, /matches AFFINE_DEPLOYMENT_ID/);
});

test('a mismatched stamp names both the stored and the configured id', t => {
  const text = renderReport(
    report({
      verdict: 'IDENTITY_MISMATCH',
      identity: { kind: 'mismatch', stamp, configured: 'prod-b' },
    })
  );
  t.regex(text, /identity:\s+deploy-123/);
  t.regex(text, /prod-b/);
});

test('a corrupt stamp renders as unreadable, never as "not stamped"', t => {
  // D18: a stamp row that exists but cannot be parsed refuses rather than
  // being silently overwritten. Rendering it as "not stamped" would tell the
  // operator the opposite of what happened.
  const text = renderReport(
    report({ verdict: 'IDENTITY_MISMATCH', identity: { kind: 'corrupt' } })
  );
  t.regex(text, /identity:\s+PRESENT BUT UNREADABLE/);
  t.notRegex(text, /not stamped/);
});

test('a long statement is excerpted and says how much was dropped', t => {
  const long = `ALTER TABLE "t" ${'DROP COLUMN "c", '.repeat(40)}DROP COLUMN "last"`;
  const text = renderReport(
    report({
      verdict: 'DB_BEHIND',
      rollbackPossible: false,
      pending: [
        {
          name: 'm2',
          tier: 'BLOCKING',
          hits: [
            { tier: 'BLOCKING', rule: 'drop-column', line: 3, statement: long },
          ],
        },
      ],
    })
  );
  t.regex(text, /\+\d+ chars/);
  // The classifier keeps the full statement; truncation must not be silent.
  t.false(text.includes(long));
});

test('UNREADABLE suppresses known/applied/ahead/pending rather than rendering every applied migration as divergence', t => {
  // `CompatReport`'s own doc comment: with `known: []`, `buildReport` computes
  // `ahead` as every applied migration that isn't in `known` — i.e. ALL of
  // them. Printed plainly this reads as "migrated by a newer binary" when the
  // truth is "this binary could not find its own migrations directory".
  const text = renderReport(
    report({
      verdict: 'UNREADABLE',
      reason:
        'the migrations directory could not be located, so compatibility cannot be determined',
      known: [],
      applied: ['m1', 'm2', 'm3'],
      ahead: ['m1', 'm2', 'm3'],
      pending: [],
      rollbackPossible: null,
    })
  );
  t.regex(text, /verdict:\s+UNREADABLE/);
  t.regex(text, /migrations known:\s+unknown/);
  t.notRegex(text, /in database but NOT in this binary/);
  t.notRegex(text, /m1/);
  t.notRegex(text, /migrations applied:/);
});

test('a half-applied migration is not double-counted as cleanly applied', t => {
  // `compat.ts`'s doc: a renderer "must not print the failed migration as if
  // it were also cleanly applied" — but `applied` contains it (not rolled
  // back) alongside `failed` (not finished). 5 clean + 1 half-applied must
  // not render as a bare "6".
  const text = renderReport(
    report({
      verdict: 'MIGRATION_FAILED',
      applied: ['m1', 'm2', 'm3', 'm4', 'm5', 'm6'],
      failed: ['m6'],
      rollbackPossible: null,
    })
  );
  t.regex(text, /migrations applied:\s+6 \(1 unfinished\)/);
});

test('summarizePending collapses the pending list to a bare count', t => {
  // `db check` on a fresh VIRGIN install has every migration pending, several
  // BLOCKING — full detail there is 261 lines of noise on the one path that
  // is unambiguously safe. The option lets a caller ask for just the count.
  const text = renderReport(
    report({
      verdict: 'VIRGIN',
      populated: false,
      rollbackPossible: false,
      pending: [
        {
          name: 'm1',
          tier: 'BLOCKING',
          hits: [
            {
              tier: 'BLOCKING',
              rule: 'drop-table',
              line: 1,
              statement: 'DROP TABLE "x"',
            },
          ],
        },
      ],
    }),
    { summarizePending: true }
  );
  t.regex(text, /pending \(1\)/);
  t.notRegex(text, /drop-table/);
});
