/**
 * Postgres SQLSTATE for "relation does not exist", as surfaced by a raw
 * `$queryRaw` failure in `error.meta.code`.
 */
const UNDEFINED_TABLE = '42P01';

/**
 * Prisma Client's own error code for "the model's table does not exist",
 * thrown by model-based calls like `db.user.count()` at the top-level
 * `error.code` — distinct from the Postgres SQLSTATE above, which a raw
 * query throws instead. Both shapes are real and independently verified;
 * neither is a superset of the other.
 */
const PRISMA_TABLE_NOT_FOUND = 'P2021';

/**
 * True when `error` is a Prisma/Postgres "table does not exist" failure —
 * the normal state of a schema that hasn't been migrated (yet), or hasn't
 * been migrated far enough to have the table a caller wants.
 *
 * Lifted out of `db-state.ts` so `identity.ts` can degrade the same way
 * `readDbState` does: on a fresh install the predeploy gate runs BEFORE
 * `prisma migrate deploy`, so `app_configs` does not exist yet, and a raw
 * `P2021`/`42P01` here is the same "nothing to see" signal as a missing
 * `_prisma_migrations` or `users` table, not a real error.
 */
export function isUndefinedTable(error: unknown): boolean {
  if (!error || typeof error !== 'object') {
    return false;
  }
  if ((error as { code?: unknown }).code === PRISMA_TABLE_NOT_FOUND) {
    return true;
  }
  const meta = (error as { meta?: { code?: unknown } }).meta;
  return !!meta && String(meta.code) === UNDEFINED_TABLE;
}
