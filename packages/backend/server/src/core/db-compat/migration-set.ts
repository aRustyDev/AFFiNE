import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const MIGRATIONS_DIRNAME = 'migrations';

/**
 * Candidate roots, in priority order.
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
    process.cwd(),
    resolve(here, '..', '..', '..'),
    resolve(dirname(process.argv[1] ?? process.cwd()), '..'),
  ];
}

export function resolveMigrationsDir(
  candidates: string[] = defaultCandidates()
): string | null {
  for (const candidate of candidates) {
    const dir = join(candidate, MIGRATIONS_DIRNAME);
    if (existsSync(dir) && statSync(dir).isDirectory()) {
      return dir;
    }
  }
  return null;
}

export interface MigrationSet {
  dir: string;
  /** Migration directory names, lexicographically sorted — prisma's own order. */
  names: string[];
  /** Contents of `<name>/migration.sql`, or '' when absent. */
  sql(name: string): string;
}

export function loadMigrationSet(
  dir: string | null = resolveMigrationsDir()
): MigrationSet | null {
  if (!dir || !existsSync(dir)) {
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
      return existsSync(file) ? readFileSync(file, 'utf8') : '';
    },
  };
}
