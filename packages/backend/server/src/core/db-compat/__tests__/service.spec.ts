import { PrismaClient } from '@prisma/client';
import test from 'ava';

import type { CompatReport } from '../compat';
import { DEPLOYMENT_STAMP_ID, readStamp, writeStamp } from '../identity';
import { DbCompatService, decide } from '../service';

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

// Minor fix: `decide()` used to ignore `report.populated` entirely, so an
// unstamped database that is EQUAL/DB_BEHIND but genuinely empty (exactly
// the state right after `prisma migrate deploy` on a brand-new install, the
// point where `db stamp` now runs) was logged as "ADOPTING a pre-existing
// database" — or worse, refused over a BLOCKING migration — about a database
// holding zero rows. `populated: false` must select fresh-install and
// bypass the gate, the same as VIRGIN.
test('EQUAL with populated: false adopts as fresh-install, not implicit', t => {
  const decision = decide(report({ populated: false }), { adopt: false });
  t.true(decision.ok);
  t.is(decision.adopt, 'fresh-install');
});

test('DB_BEHIND with a BLOCKING pending migration but populated: false does not refuse — nothing to protect', t => {
  const decision = decide(
    report({
      verdict: 'DB_BEHIND',
      pending: [{ name: 'm2', tier: 'BLOCKING', hits: [] }],
      rollbackPossible: false,
      populated: false,
    }),
    { adopt: false }
  );
  t.true(decision.ok);
  t.is(decision.adopt, 'fresh-install');
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

test('UNREADABLE refuses to mutate but reports as undetermined', t => {
  const decision = decide(
    report({ verdict: 'UNREADABLE', rollbackPossible: null }),
    { adopt: false }
  );
  t.false(decision.ok);
  t.is(decision.adopt, null);
  t.true(decision.bootMayContinue);
});

// Important fix: the REFUSING_VERDICTS branch and the UNREADABLE branch used
// to return byte-identical shapes, so a caller (the boot guard, Task 5)
// would have to reach into `decision.report.verdict` to recover design D9 —
// and the obvious `if (!decision.ok) throw` would take the whole fleet down
// on a packaging fault, exactly what D9 exists to prevent. `bootMayContinue`
// makes the asymmetry part of the decision's own contract.
test('bootMayContinue is true only for UNREADABLE, not for a genuine refusal like DB_AHEAD', t => {
  t.true(
    decide(report({ verdict: 'UNREADABLE' }), { adopt: false }).bootMayContinue
  );
  t.false(
    decide(report({ verdict: 'DB_AHEAD' }), { adopt: false }).bootMayContinue
  );
});

// ---------------------------------------------------------------------------
// DbCompatService — integration-level tests against real scratch schemas.
//
// Before the Critical fix, ALL coverage of this module was against the pure
// `decide()` function above; `report()`, `check()`, and `stamp()` — where
// the P2021 crash, the corrupt-stamp fail-open, and the populated:false
// misclassification actually lived — had zero tests. These close that gap
// using the same scratch-schema technique as `db-state.spec.ts`.
// ---------------------------------------------------------------------------

const db = new PrismaClient();

function requireDatabaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) {
    throw new Error(
      'DATABASE_URL must be set to run service.spec.ts against a real Postgres instance'
    );
  }
  return url;
}

function scratchClient(schema: string): PrismaClient {
  const url = new URL(requireDatabaseUrl());
  url.searchParams.set('schema', schema);
  return new PrismaClient({ datasources: { db: { url: url.toString() } } });
}

async function withScratchSchema<T>(
  name: string,
  setup: (schema: string) => Promise<void>,
  fn: (client: PrismaClient) => Promise<T>
): Promise<T> {
  // Drop before create so a leftover schema from an abnormally-terminated
  // previous run doesn't turn into an error instead of the test just
  // working — this database may be shared with other active work.
  await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${name}" CASCADE`);
  await db.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${name}"`);
  await setup(name);
  const scratch = scratchClient(name);
  try {
    return await fn(scratch);
  } finally {
    await scratch.$disconnect();
    await db.$executeRawUnsafe(`DROP SCHEMA IF EXISTS "${name}" CASCADE`);
  }
}

async function createAppConfigsTable(schema: string): Promise<void> {
  await db.$executeRawUnsafe(`
    CREATE TABLE "${schema}"."app_configs" (
      id varchar PRIMARY KEY,
      value jsonb NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      last_updated_by varchar
    )
  `);
}

test.before(async () => {
  await db.$connect();
});

test.after.always(async () => {
  await db.$disconnect();
});

test('report() against a totally empty scratch schema does not throw and yields VIRGIN', async t => {
  await withScratchSchema(
    'db_compat_service_virgin',
    async () => {
      // No tables at all — the exact state of a fresh install BEFORE
      // `prisma migrate deploy`, where the Critical bug lived: neither
      // `_prisma_migrations`, `users`, nor `app_configs` exist yet.
    },
    async scratch => {
      const service = new DbCompatService(scratch);
      let rep: CompatReport | undefined;
      await t.notThrowsAsync(async () => {
        rep = await service.report();
      });
      t.is(rep?.verdict, 'VIRGIN');
    }
  );
});

test('check() classifies without writing to app_configs', async t => {
  await withScratchSchema(
    'db_compat_service_check_noop',
    createAppConfigsTable,
    async scratch => {
      const service = new DbCompatService(scratch);
      const decision = await service.check({});
      t.is(decision.report.verdict, 'VIRGIN');
      t.true(decision.ok);
      t.is(await scratch.appConfig.count(), 0);
    }
  );
});

test('stamp() on a fresh install is idempotent: one row, adoption recorded once', async t => {
  await withScratchSchema(
    'db_compat_service_stamp_idempotent',
    createAppConfigsTable,
    async scratch => {
      const service = new DbCompatService(scratch);

      await service.stamp();
      const first = await readStamp(scratch);
      t.is(first.stamp?.adoptionMode, 'fresh-install');
      const firstAdoptedAt = first.stamp?.adoptedAt;

      await service.stamp();
      const second = await readStamp(scratch);
      // Not re-adopted: adoptedAt/adoptionMode are unchanged, and there is
      // still exactly one row — the second call only refreshes
      // `lastMigratedBy` (verified in the next test).
      t.is(second.stamp?.adoptionMode, 'fresh-install');
      t.is(second.stamp?.adoptedAt, firstAdoptedAt);
      t.is(
        await scratch.appConfig.count({ where: { id: DEPLOYMENT_STAMP_ID } }),
        1
      );
    }
  );
});

test('stamp() on an already-adopted database updates only lastMigratedBy', async t => {
  await withScratchSchema(
    'db_compat_service_stamp_touch',
    createAppConfigsTable,
    async scratch => {
      await writeStamp(scratch, {
        deploymentId: 'existing-prod',
        adoptedAt: '2020-01-01T00:00:00.000Z',
        adoptionMode: 'explicit',
        adoptedBy: { version: '0.20.0', buildSha: 'old1111' },
      });

      const service = new DbCompatService(scratch);
      await service.stamp();

      const after = await readStamp(scratch);
      t.is(after.stamp?.deploymentId, 'existing-prod');
      t.is(after.stamp?.adoptedAt, '2020-01-01T00:00:00.000Z');
      t.is(after.stamp?.adoptionMode, 'explicit');
      t.is(after.stamp?.adoptedBy.version, '0.20.0');
      t.truthy(after.stamp?.lastMigratedBy);
      t.is(
        await scratch.appConfig.count({ where: { id: DEPLOYMENT_STAMP_ID } }),
        1
      );
    }
  );
});

test('stamp() refuses without writing when the current verdict refuses', async t => {
  await withScratchSchema(
    'db_compat_service_stamp_refuses',
    async schema => {
      await createAppConfigsTable(schema);
      // A stamp naming a different deployment than the one configured below
      // forces IDENTITY_MISMATCH, a refusing verdict.
      await db.$executeRawUnsafe(`
        INSERT INTO "${schema}"."app_configs" (id, value)
        VALUES ('${DEPLOYMENT_STAMP_ID}', '{"deploymentId":"prod-a","adoptedAt":"2026-01-01T00:00:00.000Z","adoptionMode":"explicit","adoptedBy":{"version":"0.27.0","buildSha":"abc"}}')
      `);
    },
    async scratch => {
      const previous = process.env.AFFINE_DEPLOYMENT_ID;
      process.env.AFFINE_DEPLOYMENT_ID = 'prod-b';
      try {
        const service = new DbCompatService(scratch);
        await service.stamp();
        const after = await readStamp(scratch);
        // Untouched: still names prod-a, stamp() must not have overwritten it.
        t.is(after.stamp?.deploymentId, 'prod-a');
      } finally {
        if (previous === undefined) {
          delete process.env.AFFINE_DEPLOYMENT_ID;
        } else {
          process.env.AFFINE_DEPLOYMENT_ID = previous;
        }
      }
    }
  );
});
