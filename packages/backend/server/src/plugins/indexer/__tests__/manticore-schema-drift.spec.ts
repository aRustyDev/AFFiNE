// WOVEN FORK-LOCAL regression test (bead affine-adi).
//
// blockSQL is CREATE TABLE IF NOT EXISTS and createTables() is only ever called from a
// data migration, so a Manticore table created before an upstream commit that adds
// columns never gains them and nothing in the tree repairs it. Upstream's own answer is
// a migration per schema change (1763800000000-rebuild-manticore-mixed-script-indexes),
// but upstream FORGOT for ee899a267b (#15448), and that omission broke doc search on
// the woven deployment. repairManticoreSchemaDrift() detects the drift instead.
//
// The stale column list below is not invented: it is the live block table of
// https://affine.apps.woven, read on 2026-09-08 with
// `mysql -h127.0.0.1 -P9306 -e "DESCRIBE block"` inside pod
// affine-manticore-69997c77c6-r8rks. 29 columns, missing exactly the seven that #15448
// added.
//
// Drift is measured against the Zod table schemas rather than the CREATE TABLE string,
// because write() does schema.parse(mapKeys(d, snakeCase)) — those keys ARE the
// snake_case column names, so they are the authority on what the write path produces.
import test from 'ava';

import { createModule } from '../../../__tests__/create-module';
import { ConfigModule } from '../../../base/config';
import { ServerConfigModule } from '../../../core/config';
import { SearchProviderType } from '../config';
import { IndexerModule, IndexerService } from '../index';
import { ManticoresearchProvider } from '../providers';
import { BlockSchema, DocSchema, SearchTable } from '../tables';

const module = await createModule({
  imports: [
    IndexerModule,
    ServerConfigModule,
    ConfigModule.override({ indexer: { enabled: true } }),
  ],
  providers: [IndexerService],
});
const indexerService = module.get(IndexerService);

test.after.always(async () => {
  await module.close();
});

/** The seven columns upstream ee899a267b (#15448) added to blockSQL. */
const ADDED_BY_15448 = new Set([
  'unit_id',
  'projection_version',
  'source_hash',
  'visibility',
  'element_id',
  'frame_id',
  'source_block_id',
]);

const healthyBlockColumns = () => Object.keys(BlockSchema.shape);
const healthyDocColumns = () => Object.keys(DocSchema.shape);
/** The deployment's real, measured stale schema. */
const staleBlockColumns = () =>
  healthyBlockColumns().filter(column => !ADDED_BY_15448.has(column));

interface FakeManticore {
  recreated: SearchTable[];
}

function fakeManticore(columnsByTable: Partial<Record<SearchTable, string[]>>) {
  const provider = Object.create(
    ManticoresearchProvider.prototype
  ) as ManticoresearchProvider & FakeManticore;
  // `type` is an INSTANCE FIELD on ManticoresearchProvider, not a prototype property,
  // and Object.create does not run field initializers — so it must be set by hand.
  // Without it SearchTableMappingStrings[provider.type] is undefined and the repair
  // loop throws on Object.keys(undefined). Object.create is still the right way to
  // build this fake, because repairManticoreSchemaDrift gates on `instanceof
  // ManticoresearchProvider` and a plain object literal would not pass that.
  provider.type = SearchProviderType.Manticoresearch;
  provider.recreated = [];
  provider.listTableColumns = async (table: SearchTable) =>
    columnsByTable[table] ?? [];
  provider.recreateTable = async (table: SearchTable) => {
    provider.recreated.push(table);
  };
  return provider;
}

function stubService(provider: unknown) {
  const requeued: string[] = [];
  const service = indexerService as unknown as {
    factory: { get: () => unknown };
    models: { workspace: unknown };
    queue: unknown;
  };
  service.factory.get = () => provider;
  service.models = {
    ...service.models,
    workspace: {
      list: async (where: { sid?: { gt?: number } }) =>
        where?.sid?.gt === 0 ? [{ id: 'ws-1', sid: 1 }] : [],
      update: async (id: string) => {
        requeued.push(id);
      },
    },
  } as typeof service.models;
  service.queue = { add: async () => {} };
  return requeued;
}

test('a table missing the #15448 columns is detected, rebuilt and requeued', async t => {
  const provider = fakeManticore({
    [SearchTable.block]: staleBlockColumns(),
    [SearchTable.doc]: healthyDocColumns(),
  });
  const requeued = stubService(provider);

  const repaired = await indexerService.repairManticoreSchemaDrift();

  t.deepEqual(repaired, [SearchTable.block]);
  t.deepEqual(provider.recreated, [SearchTable.block]);
  t.deepEqual(
    requeued,
    ['ws-1'],
    'dropping a table without requeueing would leave search empty forever, because autoIndexWorkspaces skips indexed=true'
  );
});

test('a healthy schema repairs nothing and requeues nothing', async t => {
  const provider = fakeManticore({
    [SearchTable.block]: healthyBlockColumns(),
    [SearchTable.doc]: healthyDocColumns(),
  });
  const requeued = stubService(provider);

  const repaired = await indexerService.repairManticoreSchemaDrift();

  t.deepEqual(repaired, []);
  t.deepEqual(provider.recreated, []);
  t.deepEqual(requeued, []);
});

test('an extra column is not drift — upstream removing one must not empty search', async t => {
  const provider = fakeManticore({
    [SearchTable.block]: [
      ...healthyBlockColumns(),
      'column_upstream_since_removed',
    ],
    [SearchTable.doc]: healthyDocColumns(),
  });
  stubService(provider);

  t.deepEqual(await indexerService.repairManticoreSchemaDrift(), []);
  t.deepEqual(provider.recreated, []);
});

test('a table that does not exist yet is a fresh install, not drift', async t => {
  const provider = fakeManticore({});
  stubService(provider);

  t.deepEqual(await indexerService.repairManticoreSchemaDrift(), []);
  t.deepEqual(provider.recreated, []);
});

test('a non-Manticore provider is a no-op', async t => {
  stubService({ type: 'elasticsearch' });

  t.deepEqual(await indexerService.repairManticoreSchemaDrift(), []);
});
