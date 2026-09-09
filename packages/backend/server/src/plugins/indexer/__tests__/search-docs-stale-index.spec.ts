// WOVEN FORK-LOCAL regression test (bead affine-adi).
//
// searchDocsByKeyword() reads a run of aggregate-hit fields with an unguarded `[0]`.
// Any indexed block written before upstream ee899a267b (#15448) carries none of the
// fields that commit introduced -- unitId, projectionVersion, sourceHash, visibility --
// so the field lookup is `undefined` and the subscript throws
// "Cannot read properties of undefined (reading '0')". The whole query 500s because
// one stale row is in the result set.
//
// Measured on the woven deployment 2026-09-03: workspace.search over the block table,
// asking for [docId, blockId, flavour, unitId, projectionVersion, sourceHash,
// visibility], returned a node whose `fields` object contained ONLY docId, blockId and
// flavour. Zero-hit queries succeeded; any query with a hit returned
// INTERNAL_SERVER_ERROR.
//
// The existing service.spec.ts cannot catch this: it runs against Manticoresearch,
// whose table is (re)created from blockSQL with every column present, so a field is
// never absent from a hit. The stale-index shape is therefore stubbed at the aggregate
// boundary, which is exactly where the provider hands rows to the mapping code.
import { mock } from 'node:test';

import test from 'ava';

import { createModule } from '../../../__tests__/create-module';
import { ConfigModule } from '../../../base/config';
import { ServerConfigModule } from '../../../core/config';
import { IndexerModule, IndexerService } from '../index';

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

/** A hit as a pre-#15448 index returns it: none of that commit's fields present. */
function staleBucket(docId: string, flavour: string, content: string) {
  return {
    key: docId,
    count: 1,
    hits: {
      nodes: [
        {
          fields: {
            blockId: ['block-1'],
            flavour: [flavour],
            content: [content],
            createdAt: [new Date('2026-01-01T00:00:00.000Z')],
            updatedAt: [new Date('2026-01-01T00:00:00.000Z')],
            createdByUserId: ['user-1'],
            updatedByUserId: ['user-1'],
            // absent, exactly as measured on the deployment:
            // unitId, projectionVersion, sourceHash, visibility
          },
          highlights: { content: ['<b>meeting</b> notes'] },
        },
      ],
    },
  };
}

test('searchDocsByKeyword survives a hit from a pre-#15448 index', async t => {
  mock.method(indexerService, 'aggregate', async () => ({
    buckets: [staleBucket('doc-stale', 'affine:page', 'meeting notes')],
    pagination: { count: 1, hasMore: false },
  }));

  const rows = await indexerService.searchDocsByKeyword('ws-1', 'meeting');

  t.is(
    rows.length,
    1,
    'the stale row is returned rather than crashing the query'
  );
  t.is(rows[0].docId, 'doc-stale');
  t.is(rows[0].title, 'meeting notes');
  t.is(rows[0].blockId, 'block-1');
  t.is(
    rows[0].unitId,
    undefined,
    'a field the stale row lacks is simply absent'
  );
  t.is(rows[0].projectionVersion, undefined);
  t.is(rows[0].sourceHash, undefined);
  t.is(rows[0].visibility, undefined);
});

test('searchDocsByKeyword still maps a fully populated hit', async t => {
  const bucket = staleBucket('doc-fresh', 'affine:page', 'meeting notes');
  Object.assign(bucket.hits.nodes[0].fields, {
    unitId: ['unit-1'],
    projectionVersion: [2],
    sourceHash: ['hash-1'],
    visibility: ['public'],
  });
  mock.method(indexerService, 'aggregate', async () => ({
    buckets: [bucket],
    pagination: { count: 1, hasMore: false },
  }));

  const rows = await indexerService.searchDocsByKeyword('ws-1', 'meeting');

  t.is(rows.length, 1);
  t.is(rows[0].unitId, 'unit-1');
  t.is(rows[0].projectionVersion, 2);
  t.is(rows[0].sourceHash, 'hash-1');
  t.is(rows[0].visibility, 'public');
});
