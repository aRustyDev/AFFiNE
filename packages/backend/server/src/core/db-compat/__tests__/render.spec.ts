import test from 'ava';

import type { CompatReport } from '../compat';
import { renderReport } from '../render';

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

test('states when identity is unchecked', t => {
  const text = renderReport(report({}));
  t.regex(text, /identity:\s+not stamped/);
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
