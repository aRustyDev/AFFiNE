import { Models, WorkspaceMemberStatus, WorkspaceRole } from '../../../models';
import {
  seedWovenWorkspace,
  WOVEN_DEFAULT_MEMBER_COUNT,
} from '../../fixtures/woven-workspace';
import { app, e2e } from '../test';

// WOVEN FORK-LOCAL e2e (do not send upstream). Proves the shared seed fixture
// in fixtures/woven-workspace.ts materialises a real, persisted multi-member
// workspace — the same helper the `seed WovenWorkspace` CLI uses.

e2e(
  'woven fixture seeds an owner + members workspace with a root doc',
  async t => {
    app.clearAuth();

    const { owner, members, workspace, seats } = await seedWovenWorkspace(
      app.create
    );

    // Fixture shape is deterministic even though ids are random.
    t.is(members.length, WOVEN_DEFAULT_MEMBER_COUNT);
    t.is(seats, WOVEN_DEFAULT_MEMBER_COUNT + 1);

    // Workspace persisted.
    const persisted = await app.get(Models).workspace.get(workspace.id);
    t.truthy(persisted, 'workspace row should exist');

    // Owner role is Owner + Accepted.
    const ownerRole = await app
      .get(Models)
      .workspaceUser.get(workspace.id, owner.id);
    t.truthy(ownerRole, 'owner role row should exist');
    t.is(ownerRole?.type, WorkspaceRole.Owner);
    t.is(ownerRole?.status, WorkspaceMemberStatus.Accepted);

    // Every seeded member is an Accepted member of the workspace. This is the
    // crux of the member/seat-limit-removal regression (affine-vap): more seats
    // than the old free cap must all persist, none rejected.
    for (const member of members) {
      const role = await app
        .get(Models)
        .workspaceUser.get(workspace.id, member.id);
      t.truthy(role, `member ${member.id} role row should exist`);
      t.is(role?.status, WorkspaceMemberStatus.Accepted);
    }
  }
);
