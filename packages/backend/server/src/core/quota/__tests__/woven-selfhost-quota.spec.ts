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
