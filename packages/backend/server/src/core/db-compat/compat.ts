import { classifyDdl, type DdlHit, type DdlTier } from './classify';
import {
  type DeploymentStamp,
  evaluateIdentity,
  type IdentityState,
} from './identity';
import type { MigrationSet } from './migration-set';

export type Verdict =
  | 'VIRGIN'
  | 'EQUAL'
  | 'DB_BEHIND'
  | 'DB_AHEAD'
  | 'DIVERGED'
  | 'IDENTITY_MISMATCH'
  | 'MIGRATION_FAILED'
  | 'UNREADABLE';

export interface MigrationRow {
  name: string;
  finishedAt: Date | null;
  rolledBackAt: Date | null;
}

export interface PendingMigration {
  name: string;
  tier: DdlTier;
  hits: DdlHit[];
}

export interface CompatInput {
  migrations: MigrationSet | null;
  hasMigrationsTable: boolean;
  appliedRows: MigrationRow[];
  populated: boolean;
  stamp: DeploymentStamp | null;
  configuredDeploymentId: string | null;
}

export interface CompatReport {
  verdict: Verdict;
  reason: string;
  known: string[];
  applied: string[];
  pending: PendingMigration[];
  ahead: string[];
  failed: string[];
  /** null when the question does not apply (UNREADABLE, VIRGIN, refusals). */
  rollbackPossible: boolean | null;
  populated: boolean;
  identity: IdentityState;
}

/** Verdicts that must never proceed, at either enforcement point. */
export const REFUSING_VERDICTS: ReadonlySet<Verdict> = new Set<Verdict>([
  'DB_AHEAD',
  'DIVERGED',
  'IDENTITY_MISMATCH',
  'MIGRATION_FAILED',
]);

export function buildReport(input: CompatInput): CompatReport {
  const { migrations, hasMigrationsTable, appliedRows, populated, stamp } =
    input;
  const identity = evaluateIdentity(stamp, input.configuredDeploymentId);

  const known = migrations ? [...migrations.names] : [];
  const applied = appliedRows
    .filter(row => !row.rolledBackAt)
    .map(row => row.name)
    .sort();
  const failed = appliedRows
    .filter(row => !row.finishedAt && !row.rolledBackAt)
    .map(row => row.name)
    .sort();

  const knownSet = new Set(known);
  const appliedSet = new Set(applied);

  const ahead = applied.filter(name => !knownSet.has(name));
  const behind = known.filter(name => !appliedSet.has(name));

  const pending: PendingMigration[] = migrations
    ? behind.map(name => {
        const sql = migrations.sql(name);

        // `sql()` returns null when the file is absent or unreadable. Fail
        // CLOSED: a migration we cannot read must not be reported as additive,
        // which is what treating it as an empty string would do. `classifyDdl`
        // applies the same rule to SQL it cannot parse (its `unterminated`
        // flag forces BLOCKING), so both unreadable cases gate consistently.
        if (sql === null) {
          return {
            name,
            tier: 'BLOCKING' as const,
            hits: [
              {
                tier: 'BLOCKING' as const,
                rule: 'unreadable-migration',
                line: 0,
                statement: `${name}/migration.sql is missing or unreadable`,
              },
            ],
          };
        }

        const { tier, hits } = classifyDdl(sql);
        return { name, tier, hits };
      })
    : [];

  const rollbackPossible = pending.every(item => item.tier !== 'BLOCKING');

  const report = (
    verdict: Verdict,
    reason: string,
    rollback: boolean | null
  ): CompatReport => ({
    verdict,
    reason,
    known,
    applied,
    pending,
    ahead,
    failed,
    rollbackPossible: rollback,
    populated,
    identity,
  });

  // Order matters: the most specific and most actionable message wins.
  if (!migrations) {
    return report(
      'UNREADABLE',
      'the migrations directory could not be located, so compatibility cannot be determined',
      null
    );
  }

  if (failed.length > 0) {
    return report(
      'MIGRATION_FAILED',
      `a previous migration did not finish and was not rolled back: ${failed.join(', ')}`,
      null
    );
  }

  if (identity.kind === 'mismatch') {
    return report(
      'IDENTITY_MISMATCH',
      `this database belongs to deployment "${identity.stamp.deploymentId}" but this server is configured as "${identity.configured}"`,
      null
    );
  }

  if (ahead.length > 0 && behind.length > 0) {
    return report(
      'DIVERGED',
      `migration history has branched: the database has ${ahead.join(', ')} which this binary lacks, and is missing ${behind.join(', ')}`,
      null
    );
  }

  if (ahead.length > 0) {
    return report(
      'DB_AHEAD',
      `the database was migrated by a NEWER binary and carries ${ahead.join(', ')}; refusing to downgrade`,
      null
    );
  }

  if (!hasMigrationsTable && !populated) {
    return report(
      'VIRGIN',
      'no migration history and no data — a fresh install',
      null
    );
  }

  if (pending.length > 0) {
    return report(
      'DB_BEHIND',
      `${pending.length} migration(s) pending`,
      rollbackPossible
    );
  }

  return report('EQUAL', 'the database matches this binary', true);
}
