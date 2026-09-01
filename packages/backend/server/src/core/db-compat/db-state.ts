import type { PrismaClient } from '@prisma/client';

import type { MigrationRow } from './compat';
import { isUndefinedTable } from './prisma-errors';

export interface DbState {
  hasMigrationsTable: boolean;
  rows: MigrationRow[];
  /**
   * Whether the database has user data.
   *
   * `null` means this could not be determined — the `users` table itself is
   * missing — and is distinct from `false`, which means the table exists and
   * was counted as empty. Where migration history exists
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

  // A populated database is one with real content. User count is the same
  // signal `ServerService.initialized()` uses, kept deliberately so the two
  // agree about what "pre-existing" means (grounding G7). `populated` stays
  // `null` — undetermined, not `false` — when the table itself is missing;
  // see the doc comment on `DbState.populated`.
  let populated: boolean | null;
  try {
    populated = (await db.user.count()) > 0;
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
