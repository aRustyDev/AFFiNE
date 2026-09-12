import type { PrismaClient } from '@prisma/client';

import type { MigrationRow } from './compat';
import { isUndefinedTable } from './prisma-errors';

export interface DbState {
  hasMigrationsTable: boolean;
  rows: MigrationRow[];
  /**
   * Whether the database has real content someone would be taking
   * ownership of by adopting it — counting BOTH `users` and `workspaces`
   * rows, not users alone. See the long comment in `readDbState` for why:
   * in short, AFFiNE deliberately preserves workspaces (and their
   * documents/blobs) when a user is deleted, so a database can hold real
   * content with zero user rows.
   *
   * `null` means this could not be determined — one of the two tables
   * itself is missing — and is distinct from `false`, which means both
   * tables exist and were counted as empty. Where migration history exists
   * (`hasMigrationsTable: true`), callers must not collapse `null` into
   * `false`: an undetermined population on a database that otherwise has
   * recorded history is a schema inconsistency, not a fresh install. See the
   * `SCHEMA_INCOMPLETE` verdict in `compat.ts`, which exists specifically
   * for this combination. When there is no migration history either, `null`
   * and `false` are treated alike (see `VIRGIN` in `compat.ts`) — a schema
   * with neither table is genuinely empty, not contradictory.
   */
  populated: boolean | null;
}

interface RawMigrationRow {
  migration_name: string;
  finished_at: Date | null;
  rolled_back_at: Date | null;
}

/**
 * `_prisma_migrations` is Prisma's own bookkeeping table and has no model in
 * schema.prisma, so it can only be read raw. It is absent on a virgin database,
 * which is a normal state and must not throw. See grounding G6.
 */
export async function readDbState(db: PrismaClient): Promise<DbState> {
  let rows: MigrationRow[] = [];
  let hasMigrationsTable = true;

  try {
    const raw = await db.$queryRaw<RawMigrationRow[]>`
      SELECT migration_name, finished_at, rolled_back_at FROM _prisma_migrations
      ORDER BY migration_name
    `;
    rows = raw.map(row => ({
      name: row.migration_name,
      finishedAt: row.finished_at,
      rolledBackAt: row.rolled_back_at,
    }));
  } catch (error) {
    if (!isUndefinedTable(error)) {
      throw error;
    }
    hasMigrationsTable = false;
  }

  // A populated database is one with content someone would be taking
  // ownership of by adopting it. That is NOT the same question as "has
  // anyone signed up" (`user.count() > 0` alone — what
  // `ServerService.initialized()` checks, and what this field used to be
  // tied to; see the retraction below). AFFiNE deliberately preserves
  // workspaces, documents, and blobs when a user is deleted: `Workspace`
  // has no foreign key to `User` at all, `Blob` cascades from `Workspace`
  // (not `User`), and `Snapshot.createdByUser`/`updatedByUser` are
  // `onDelete: SetNull` — the schema's own comment on `Snapshot` reads
  // "should not delete origin snapshot even if user is deleted / we only
  // delete the snapshot if the workspace is deleted". A database with real
  // workspaces and zero users — e.g. a production clone with `users`
  // truncated to scrub PII — is exactly the case the adoption gate exists
  // to protect, so `populated` must count workspaces too, not just users.
  //
  // This deliberately breaks the tie to `ServerService.initialized()` that
  // an earlier design note (grounding G7) asserted the two should share —
  // that rationale was wrong. `initialized()` answers "has setup been
  // completed"; this answers "is there content someone would be adopting
  // by proceeding". They are different questions: do not re-couple them.
  //
  // `null` — undetermined, not `false` — when EITHER table is missing: a
  // schema where one of `users`/`workspaces` exists and the other doesn't
  // is itself contradictory, and is caught by `SCHEMA_INCOMPLETE` in
  // `compat.ts` rather than silently treated as empty. `user.count()` is
  // checked first purely as a short-circuit (the common case of an
  // established, active deployment skips a second query) — it carries no
  // special authority over `workspace.count()`.
  let populated: boolean | null;
  try {
    const users = await db.user.count();
    populated = users > 0 || (await db.workspace.count()) > 0;
  } catch (error) {
    if (!isUndefinedTable(error)) {
      throw error;
    }
    populated = null;
  }

  return {
    hasMigrationsTable,
    rows,
    populated,
  };
}
