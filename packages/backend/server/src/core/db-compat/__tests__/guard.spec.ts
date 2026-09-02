import { Logger } from '@nestjs/common';
import test from 'ava';

import { enforce } from '../guard';
import type { CompatDecision } from '../service';

// `bootMayContinue` is the field the guard keys on (D20). It is true for every
// `ok` decision and, uniquely among refusals, for UNREADABLE.
const decision = (
  ok: boolean,
  verdict = 'DB_AHEAD',
  bootMayContinue = ok
): CompatDecision => ({
  ok,
  refusal: ok ? null : 'the database was migrated by a NEWER binary',
  adopt: null,
  bootMayContinue,
  report: {
    verdict: verdict as never,
    reason: 'r',
    known: [],
    applied: [],
    pending: [],
    ahead: ['m9'],
    failed: [],
    rollbackPossible: null,
    populated: true,
    identity: { kind: 'absent' },
  },
});

const collect = () => {
  const errors: string[] = [];
  const logger = {
    error: (m: string) => errors.push(m),
    log: () => {},
  } as unknown as Logger;
  return { logger, errors };
};

test('a passing decision does not throw', t => {
  const { logger } = collect();
  t.notThrows(() => enforce(decision(true), { bypassed: false, logger }));
});

test('a refusing decision throws, so the port is never bound', t => {
  const { logger } = collect();
  t.throws(() => enforce(decision(false), { bypassed: false, logger }), {
    message: /NEWER binary/,
  });
});

test('UNREADABLE at boot logs an error but does NOT throw (design D9)', t => {
  const { logger, errors } = collect();
  t.notThrows(() =>
    enforce(decision(false, 'UNREADABLE', true), { bypassed: false, logger })
  );
  t.true(errors.some(m => /UNREADABLE/.test(m)));
});

test('the guard keys on bootMayContinue, not on the verdict string (D20)', t => {
  // If a future verdict is given boot-continue semantics, the guard must honour
  // it without being edited. Conversely a refusal with bootMayContinue false
  // must throw even if someone mislabels the verdict.
  const { logger } = collect();
  t.notThrows(() =>
    enforce(decision(false, 'SOME_FUTURE_VERDICT', true), {
      bypassed: false,
      logger,
    })
  );
  t.throws(() =>
    enforce(decision(false, 'UNREADABLE', false), { bypassed: false, logger })
  );
});

test('the bypass suppresses the throw and logs at ERROR every time', t => {
  const { logger, errors } = collect();
  t.notThrows(() => enforce(decision(false), { bypassed: true, logger }));
  t.true(errors.some(m => /AFFINE_DB_COMPAT_SKIP/.test(m)));
  t.true(errors.some(m => /DB_AHEAD/.test(m)));
});
