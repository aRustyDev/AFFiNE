import { randomUUID } from 'node:crypto';

import { PrismaClient } from '@prisma/client';
import ava, { ExecutionContext, TestFn } from 'ava';

import {
  createTestingModule,
  type TestingModule,
} from '../../../__tests__/utils';
import { ConfigFactory } from '../../../base';
import { Models, WorkspaceMemberStatus, WorkspaceRole } from '../../../models';
import { EntitlementModule } from '../../entitlement';
import { QuotaService } from '../service';
import { QuotaServiceModule } from '../service.module';
import { QuotaStateService } from '../state';

interface Context {
  module: TestingModule;
  db: PrismaClient;
  models: Models;
  quota: QuotaService;
  state: QuotaStateService;
  config: ConfigFactory;
}

const test = ava.serial as TestFn<Context>;

const INHERIT = -1;
const ONE_GB = 1024 * 1024 * 1024;
const ONE_MB = 1024 * 1024;

test.before(async t => {
  const module = await createTestingModule({
    imports: [EntitlementModule, QuotaServiceModule],
  });
  t.context.module = module;
  t.context.db = module.get(PrismaClient);
  t.context.models = module.get(Models);
  t.context.quota = module.get(QuotaService);
  t.context.state = module.get(QuotaStateService);
  t.context.config = module.get(ConfigFactory);
});

test.beforeEach(async t => {
  await t.context.module.initTestingDB();
  // ConfigFactory.override merges and is sticky across tests, so every test sets all three
  // explicitly rather than relying on the registered defaults.
  setFloors(t, { seat: INHERIT, storage: INHERIT, blob: INHERIT });
});

test.after.always(async t => {
  await t.context.module.close();
});

function setFloors(
  t: ExecutionContext<Context>,
  floors: { seat: number; storage: number; blob: number }
) {
  t.context.config.override({
    woven: {
      selfhostSeatLimit: floors.seat,
      selfhostStorageQuota: floors.storage,
      selfhostBlobLimit: floors.blob,
    },
  });
}

async function asSelfhosted<T>(run: () => Promise<T>): Promise<T> {
  const previous = globalThis.env.DEPLOYMENT_TYPE;
  // @ts-expect-error test mutates the env singleton for deployment-specific quota semantics
  globalThis.env.DEPLOYMENT_TYPE = 'selfhosted';
  try {
    return await run();
  } finally {
    // @ts-expect-error restore mutable test env singleton
    globalThis.env.DEPLOYMENT_TYPE = previous;
  }
}

async function createWorkspace(t: ExecutionContext<Context>) {
  const owner = await t.context.models.user.create({
    email: `${randomUUID()}@affine.pro`,
  });
  const workspace = await t.context.models.workspace.create(owner.id);

  return { owner, workspace };
}

async function addAcceptedMembers(
  t: ExecutionContext<Context>,
  workspaceId: string,
  count: number
) {
  for (let index = 0; index < count; index++) {
    const member = await t.context.models.user.create({
      email: `${randomUUID()}@affine.pro`,
    });
    await t.context.models.workspaceUser.set(
      workspaceId,
      member.id,
      WorkspaceRole.Collaborator,
      { status: WorkspaceMemberStatus.Accepted }
    );
  }
}

test('default (-1): an 11th member is over capacity and the workspace is readonly', async t => {
  await asSelfhosted(async () => {
    const { workspace } = await createWorkspace(t);
    await addAcceptedMembers(t, workspace.id, 10);

    const state = await t.context.state.reconcileWorkspaceQuotaState(
      workspace.id
    );

    t.is(state.plan, 'selfhost_free');
    t.is(state.seatLimit, 10);
    t.is(state.memberCount, 11, 'owner + 10 collaborators');
    t.is(state.overcapacityMemberCount, 1);
    t.true(state.readonlyReasons.includes('member_overflow'));
    t.false(await t.context.quota.tryCheckSeat(workspace.id));
  });
});

test('seat floor 1000: 11 members are within capacity and the workspace is writable', async t => {
  await asSelfhosted(async () => {
    setFloors(t, { seat: 1000, storage: INHERIT, blob: INHERIT });
    const { workspace } = await createWorkspace(t);
    await addAcceptedMembers(t, workspace.id, 10);

    const state = await t.context.state.reconcileWorkspaceQuotaState(
      workspace.id
    );

    t.is(state.seatLimit, 1000);
    t.is(state.memberCount, 11);
    t.is(state.overcapacityMemberCount, 0);
    t.false(state.readonlyReasons.includes('member_overflow'));
    t.false(state.readonly);
    t.true(await t.context.quota.tryCheckSeat(workspace.id));
  });
});

test('seat floor never lowers: a floor of 1 leaves the plan value at 10', async t => {
  await asSelfhosted(async () => {
    setFloors(t, { seat: 1, storage: INHERIT, blob: INHERIT });
    const { workspace } = await createWorkspace(t);

    const state = await t.context.state.reconcileWorkspaceQuotaState(
      workspace.id
    );

    t.is(state.seatLimit, 10);
  });
});

// Every workspace-site assertion above reads its quota via resolveUserEntitlement, not the user
// row, so region 3 (the user reconcile site in state.ts) is never exercised by them — reverting
// it to `resolved.quota` would leave all of the above green. This test pins that site to its own
// observable: the persisted effectiveUserQuotaState row from reconcileUserQuotaState. The floor
// (200GB) is chosen above selfhost_free's 100GB default so the assertion is unambiguous.
test('a storage floor reaches the persisted user quota projection', async t => {
  await asSelfhosted(async () => {
    const { owner } = await createWorkspace(t);
    setFloors(t, { seat: INHERIT, storage: 200 * ONE_GB, blob: INHERIT });

    await t.context.state.reconcileUserQuotaState(owner.id);
    const row = await t.context.db.effectiveUserQuotaState.findUnique({
      where: { userId: owner.id },
    });

    t.is(row?.storageQuota, BigInt(200 * ONE_GB));
  });
});

// Blob.size is Int @db.Integer (schema.prisma:1150), so a single row cannot exceed int4
// (~2.1GB). Split the total across <=1GB rows; upstream does the same thing by calling its
// own single-row addBlob in a loop (state.spec.ts:402-404).
async function addBlob(
  t: ExecutionContext<Context>,
  workspaceId: string,
  size: number
) {
  let remaining = size;
  while (remaining > 0) {
    const chunk = Math.min(remaining, ONE_GB);
    await t.context.models.blob.upsert({
      workspaceId,
      key: randomUUID(),
      mime: 'application/octet-stream',
      size: chunk,
    });
    remaining -= chunk;
  }
}

test('default (-1): storage past the plan quota makes the workspace readonly', async t => {
  await asSelfhosted(async () => {
    const { workspace } = await createWorkspace(t);
    await addBlob(t, workspace.id, 101 * ONE_GB);

    const state = await t.context.state.reconcileWorkspaceQuotaState(
      workspace.id
    );

    t.is(state.storageQuota, BigInt(100 * ONE_GB));
    t.true(state.readonlyReasons.includes('storage_overflow'));
    t.is(
      state.usedStorageQuota,
      BigInt(101 * ONE_GB),
      'addBlob must persist exactly the requested total, not a rounded-up multiple'
    );
  });
});

test('storage floor 900GB: the same usage is within quota and not readonly', async t => {
  await asSelfhosted(async () => {
    setFloors(t, { seat: INHERIT, storage: 900 * ONE_GB, blob: INHERIT });
    const { workspace } = await createWorkspace(t);
    await addBlob(t, workspace.id, 101 * ONE_GB);

    const state = await t.context.state.reconcileWorkspaceQuotaState(
      workspace.id
    );

    t.is(state.storageQuota, BigInt(900 * ONE_GB));
    t.false(state.readonlyReasons.includes('storage_overflow'));
    t.false(state.readonly);
  });
});

test('blob floor 500MB raises the per-file limit in the projection', async t => {
  await asSelfhosted(async () => {
    setFloors(t, { seat: INHERIT, storage: INHERIT, blob: 500 * ONE_MB });
    const { workspace } = await createWorkspace(t);

    const state = await t.context.state.reconcileWorkspaceQuotaState(
      workspace.id
    );

    t.is(state.blobLimit, BigInt(500 * ONE_MB));
  });
});

test('blob floor also reaches the calculator the upload path uses', async t => {
  await asSelfhosted(async () => {
    setFloors(t, { seat: INHERIT, storage: INHERIT, blob: 500 * ONE_MB });
    const { workspace } = await createWorkspace(t);

    const checkExceeded = await t.context.quota.getWorkspaceQuotaCalculator(
      workspace.id
    );

    t.is(
      checkExceeded(400 * ONE_MB),
      undefined,
      '400MB is under the raised per-file limit, and nothing else is exceeded either'
    );
    t.truthy(
      checkExceeded(600 * ONE_MB)?.blobQuotaExceeded,
      '600MB is still over it'
    );
  });
});

test('cloud deployment: floors are inert', async t => {
  // NOT wrapped in asSelfhosted — ava.config.js sets DEPLOYMENT_TYPE=affine, i.e. cloud.
  setFloors(t, { seat: 1000, storage: 900 * ONE_GB, blob: 500 * ONE_MB });
  const { workspace } = await createWorkspace(t);
  await addAcceptedMembers(t, workspace.id, 10);

  const state = await t.context.state.reconcileWorkspaceQuotaState(
    workspace.id
  );

  // Exact values from plan_catalog's default ('free') arm — asserting mere inequality with the
  // floor would also pass on garbage or on undefined.
  t.is(state.plan, 'free');
  t.is(state.seatLimit, 3);
  t.is(state.storageQuota, BigInt(10 * ONE_GB));
  t.is(state.blobLimit, BigInt(10 * ONE_MB));

  // The same 11 members that a seat floor rescues on self-hosted must stay over capacity here.
  t.is(state.memberCount, 11);
  t.is(state.overcapacityMemberCount, 8);
  t.true(state.readonlyReasons.includes('member_overflow'));
});
