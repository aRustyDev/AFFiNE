import { createFactory, Mockers } from '../mocks';
import type { MockedUser } from '../mocks/user.mock';
import type { MockedWorkspace } from '../mocks/workspace.mock';

/**
 * WOVEN FORK-LOCAL test fixture (do not send upstream).
 *
 * A deterministic-shape workspace fixture: one owner plus N accepted members,
 * with a real root-doc snapshot (like production). Both the seed CLI
 * (`src/seed/index.ts` → `seed WovenWorkspace`) and at least one e2e test
 * (`src/__tests__/e2e/woven/*.spec.ts`) build the fixture through this single
 * helper, so "the seeded fixture" and "the fixture an e2e asserts against" are
 * the same code path.
 *
 * The default seat count deliberately exceeds AFFiNE's historical free
 * self-host seat cap, so this doubles as the regression fixture for the
 * fork-local member/seat-limit removal (bead affine-vap; fork strategy
 * affine-cm9): a green e2e here means multi-member workspaces seed and persist
 * with no seat gate.
 *
 * IDs are faker-random by default so the fixture is safe to build repeatedly
 * against a shared test DB (the new e2e harness does NOT truncate between
 * files). Pin `workspaceId` / `ownerEmail` only when a stable identity is
 * required (e.g. a one-shot manual seed you want to look up by hand).
 */

type Create = ReturnType<typeof createFactory>;

/** Accepted seats beyond the owner. Chosen to exceed the old free-tier cap. */
export const WOVEN_DEFAULT_MEMBER_COUNT = 4;

export interface WovenWorkspaceOptions {
  /** Number of accepted members to add in addition to the owner. */
  memberCount?: number;
  /** Pin the owner's email for a deterministic, look-up-able fixture. */
  ownerEmail?: string;
  /** Pin the workspace id for a deterministic, look-up-able fixture. */
  workspaceId?: string;
}

export interface WovenWorkspaceFixture {
  owner: MockedUser;
  /** Members added beyond the owner (does not include the owner). */
  members: MockedUser[];
  workspace: MockedWorkspace;
  /** Total accepted seats, owner included. */
  seats: number;
}

export async function seedWovenWorkspace(
  create: Create,
  options: WovenWorkspaceOptions = {}
): Promise<WovenWorkspaceFixture> {
  const memberCount = options.memberCount ?? WOVEN_DEFAULT_MEMBER_COUNT;

  const owner = await create(
    Mockers.User,
    options.ownerEmail ? { email: options.ownerEmail } : undefined
  );

  const workspace = await create(Mockers.Workspace, {
    ...(options.workspaceId ? { id: options.workspaceId } : {}),
    owner: { id: owner.id },
    // Seed the same root-doc snapshot production workspaces have.
    snapshot: true,
  });

  const members: MockedUser[] = [];
  for (let i = 0; i < memberCount; i++) {
    const member = await create(Mockers.User);
    await create(Mockers.WorkspaceUser, {
      workspaceId: workspace.id,
      userId: member.id,
    });
    members.push(member);
  }

  return { owner, members, workspace, seats: memberCount + 1 };
}
