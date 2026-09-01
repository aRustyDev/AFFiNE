import type { PrismaClient } from '@prisma/client';

import type { MigrationRow } from './compat';

export interface DbState {
  hasMigrationsTable: boolean;
  rows: MigrationRow[];
  applied: string[];
  failed: string[];
  populated: boolean;
}

interface RawMigrationRow {
  migration_name: string;
  finished_at: Date | null;
  rolled_back_at: Date | null;
}

const UNDEFINED_TABLE = '42P01';

/** Prisma Client's own error code for "the model's table does not exist",
 * thrown by model-based calls like `db.user.count()`. Distinct from the
 * Postgres SQLSTATE below, which is what a raw `$queryRaw` failure carries. */
const PRISMA_TABLE_NOT_FOUND = 'P2021';

function isUndefinedTable(error: unknown): boolean {
  if (!error || typeof error !== 'object') {
    return false;
  }
  if ((error as { code?: unknown }).code === PRISMA_TABLE_NOT_FOUND) {
    return true;
  }
  const meta = (error as { meta?: { code?: unknown } }).meta;
  if (meta && String(meta.code) === UNDEFINED_TABLE) {
    return true;
  }
  return String((error as { message?: unknown }).message ?? '').includes(
    UNDEFINED_TABLE
  );
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
  // agree about what "pre-existing" means (grounding G7).
  let populated = false;
  try {
    populated = (await db.user.count()) > 0;
  } catch (error) {
    if (!isUndefinedTable(error)) {
      throw error;
    }
  }

  return {
    hasMigrationsTable,
    rows,
    applied: rows
      .filter(row => !row.rolledBackAt)
      .map(row => row.name)
      .sort(),
    failed: rows
      .filter(row => !row.finishedAt && !row.rolledBackAt)
      .map(row => row.name)
      .sort(),
    populated,
  };
}
