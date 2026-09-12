import type { INestApplicationContext } from '@nestjs/common';
import { Logger } from '@nestjs/common';
import test from 'ava';

import { assertDatabaseCompatible, enforce } from '../guard';
import type { CompatDecision, DbCompatService } from '../service';

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

// Important 1 (review): `server.ts` calls this with `bufferLogs: true` still
// in effect, and the buffer is only flushed inside `app.listen()`'s callback
// — a throw here means it never runs and any log-only report is silently
// dropped. The thrown Error's message is what actually reaches the operator
// (Node prints it unconditionally), so the full report must live THERE, not
// only in a `logger.error()` call.
test("the thrown error's message contains the full rendered report (Important 1)", t => {
  const { logger } = collect();
  const error = t.throws(() =>
    enforce(decision(false), { bypassed: false, logger })
  );
  t.truthy(error);
  // `renderReport` output, not the bare refusal string: the ahead migration
  // name only appears via the report, proving it is really embedded.
  t.true(error!.message.includes('in database but NOT in this binary'));
  t.true(error!.message.includes('m9'));
});

// Minor A (review): a bypass left set is otherwise invisible until the day it
// actually suppresses something.
test('a live bypass is logged even when the decision is ok (Minor A)', t => {
  const { logger, errors } = collect();
  enforce(decision(true), { bypassed: true, logger });
  t.true(errors.some(m => /AFFINE_DB_COMPAT_SKIP/.test(m)));
});

function fakeApp(
  service: Pick<DbCompatService, 'check'>
): Pick<INestApplicationContext, 'get'> {
  return {
    get: () => service,
  } as unknown as Pick<INestApplicationContext, 'get'>;
}

// Important 4 (review): nothing exercising `enforce()` directly would notice
// if the `server.ts` wiring were deleted, or `check()` were called with the
// wrong arguments. These tests cover `assertDatabaseCompatible` itself.
test('assertDatabaseCompatible calls check() with no arguments', async t => {
  const { logger } = collect();
  const calls: unknown[][] = [];
  const service: Pick<DbCompatService, 'check'> = {
    check: (...args: unknown[]) => {
      calls.push(args);
      return Promise.resolve(decision(true));
    },
  } as unknown as Pick<DbCompatService, 'check'>;

  await assertDatabaseCompatible(fakeApp(service), logger);

  t.deepEqual(calls, [[]]);
});

test('assertDatabaseCompatible throws with the rendered report on a refusal', async t => {
  const { logger } = collect();
  const service: Pick<DbCompatService, 'check'> = {
    check: () => Promise.resolve(decision(false)),
  };

  const error = await t.throwsAsync(() =>
    assertDatabaseCompatible(fakeApp(service), logger)
  );

  t.true(error!.message.includes('m9'));
});

// Important 3 (review): `readDbState` rethrows anything that isn't a missing-
// table error — an unreachable database, or a role lacking SELECT on
// `_prisma_migrations` — before `enforce` is ever reached. Without this,
// AFFINE_DB_COMPAT_SKIP could never clear that crash, defeating the
// documented incident bypass in a crash loop.
test('a check() crash is rethrown when not bypassed (Important 3)', async t => {
  const { logger } = collect();
  const boom = new Error('connection refused');
  const service: Pick<DbCompatService, 'check'> = {
    check: () => Promise.reject(boom),
  };

  const error = await t.throwsAsync(() =>
    assertDatabaseCompatible(fakeApp(service), logger)
  );

  t.is(error, boom);
});

test('a check() crash is swallowed with an ERROR log when bypassed (Important 3)', async t => {
  const { logger, errors } = collect();
  const previous = process.env.AFFINE_DB_COMPAT_SKIP;
  process.env.AFFINE_DB_COMPAT_SKIP = '1';
  try {
    const service: Pick<DbCompatService, 'check'> = {
      check: () => Promise.reject(new Error('connection refused')),
    };

    await t.notThrowsAsync(() =>
      assertDatabaseCompatible(fakeApp(service), logger)
    );
    t.true(errors.some(m => /AFFINE_DB_COMPAT_SKIP/.test(m)));
    t.true(errors.some(m => /connection refused/.test(m)));
  } finally {
    if (previous === undefined) {
      delete process.env.AFFINE_DB_COMPAT_SKIP;
    } else {
      process.env.AFFINE_DB_COMPAT_SKIP = previous;
    }
  }
});
