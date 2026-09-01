/**
 * See .claude/plans/adopt-existing-database/DESIGN.md and PLAN.md for the
 * G5 grounding cited below.
 */

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const MIGRATIONS_DIRNAME = 'migrations';
const LOCK_FILENAME = 'migration_lock.toml';

/**
 * Candidate roots, in priority order.
 *
 * Bundle-relative candidates come first: `migrations` is a generic directory
 * name, and a bundle-relative path can only ever resolve to this server's own
 * shipped copy, whereas `process.cwd()` could land in a directory owned by
 * some other tool (Flyway, Rails) that happens to have a `migrations/` of its
 * own — a known hazard (see the design's mis-resolution note). `process.cwd()`
 * stays as a last-resort fallback.
 *
 * In the published image cwd is `/app` and the directory is `/app/migrations`;
 * in development cwd is `packages/backend/server`. The bundle-relative
 * fallbacks cover `node dist/main.js` invoked from somewhere else. See
 * grounding G5 — the directory demonstrably ships, because
 * `prisma migrate deploy` needs it at runtime.
 */
function defaultCandidates(): string[] {
  const here = import.meta.dirname;
  return [
    resolve(here, '..', '..', '..'),
    resolve(dirname(process.argv[1] ?? process.cwd()), '..'),
    process.cwd(),
  ];
}

function isMigrationsDir(dir: string): boolean {
  const stat = statSync(dir, { throwIfNoEntry: false });
  if (!stat?.isDirectory()) {
    return false;
  }
  // Require the prisma lock file as a discriminator — `migrations` alone is a
  // generic name that a foreign tool's directory could also carry.
  return !!statSync(join(dir, LOCK_FILENAME), {
    throwIfNoEntry: false,
  })?.isFile();
}

export function resolveMigrationsDir(
  candidates: string[] = defaultCandidates()
): string | null {
  for (const candidate of candidates) {
    const dir = join(candidate, MIGRATIONS_DIRNAME);
    if (isMigrationsDir(dir)) {
      return dir;
    }
  }
  return null;
}

export interface MigrationSet {
  dir: string;
  /** Migration directory names, lexicographically sorted — prisma's own order. */
  names: string[];
  /** Contents of `<name>/migration.sql`, or null when absent. */
  sql(name: string): string | null;
}

export function loadMigrationSet(
  dir: string | null = resolveMigrationsDir()
): MigrationSet | null {
  if (!dir || !statSync(dir, { throwIfNoEntry: false })?.isDirectory()) {
    return null;
  }

  const names = readdirSync(dir, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => entry.name)
    .sort();

  return {
    dir,
    names,
    sql(name: string) {
      const file = join(dir, name, 'migration.sql');
      return existsSync(file) ? readFileSync(file, 'utf8') : null;
    },
  };
}
