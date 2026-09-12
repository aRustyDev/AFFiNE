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
  | 'SCHEMA_INCOMPLETE'
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
  /**
   * Whether the database has real content — counting both `users` and
   * `workspaces` rows, not users alone; see `DbState.populated` in
   * `db-state.ts` for why. `null` means this could not be determined (one
   * of those two tables itself is missing). Where migration history exists
   * (`hasMigrationsTable: true`), `null` must never be collapsed into
   * `false`: an undetermined population on a database that otherwise has
   * recorded history is a schema inconsistency (`SCHEMA_INCOMPLETE`), not
   * evidence of "empty". When there is no migration history either, `null`
   * and `false` are treated alike (see `VIRGIN` below) — a schema with
   * neither table is genuinely empty rather than contradictory.
   */
  populated: boolean | null;
  stamp: DeploymentStamp | null;
  configuredDeploymentId: string | null;
  /**
   * Whether the `app_configs` row for the stamp existed but could not be
   * parsed. Optional so existing callers/tests that never set it keep
   * compiling; `undefined` is treated the same as `false`. See
   * `IdentityState.corrupt` in `identity.ts` — a corrupt stamp is evidence of
   * a prior adoption and must refuse rather than read as "no stamp".
   */
  stampCorrupt?: boolean;
}

export interface CompatReport {
  verdict: Verdict;
  reason: string;
  /**
   * `known`, `applied`, `pending`, `ahead`, and `failed` are computed the
   * same way regardless of verdict, which makes two of them actively
   * misleading for particular verdicts. A renderer must special-case these
   * rather than print them uncritically:
   *
   * - `MIGRATION_FAILED`: the half-applied row appears in BOTH `failed` (it
   *   has no `finishedAt`) and `applied` (it has no `rolledBackAt`) —
   *   `applied` means "not rolled back", not "successfully finished". This
   *   is intentional (see the invariant on rolled-back rows in db-state.ts),
   *   but a renderer must not print the failed migration as if it were also
   *   cleanly applied.
   * - `UNREADABLE`: `known: []` and `pending: []`, because the migration set
   *   could not be loaded at all. Printed plainly this reads as "this binary
   *   carries no migrations, nothing to do" when the truth is "unknown, we
   *   couldn't look" — a renderer must suppress these lists for this verdict
   *   rather than print them.
   */
  known: string[];
  applied: string[];
  pending: PendingMigration[];
  ahead: string[];
  failed: string[];
  /**
   * Whether rollback would still be possible after the pending migrations
   * are applied. Computed from PENDING migrations only — this engine never
   * classifies migrations that are already applied, so it never asserts
   * anything about their reversibility.
   *
   * - `VIRGIN` and `DB_BEHIND`: the computed answer, derived from the DDL
   *   tiers of `pending`.
   * - `EQUAL`: `null`. Nothing is pending, so there is nothing to classify —
   *   not "yes": applied migrations were never examined.
   * - `MIGRATION_FAILED`, `IDENTITY_MISMATCH`, `DIVERGED`, `DB_AHEAD`,
   *   `SCHEMA_INCOMPLETE`: `null`. These verdicts refuse outright (see
   *   `REFUSING_VERDICTS`), so the question is moot.
   * - `UNREADABLE`: also `null`, but for a different reason — it is NOT a
   *   refusal (deliberately excluded from `REFUSING_VERDICTS`; boot logs and
   *   continues, per design D9). `null` here means nothing could be
   *   classified at all, since there is no migration set to compare against.
   */
  rollbackPossible: boolean | null;
  populated: boolean | null;
  identity: IdentityState;
}

/** Verdicts that must never proceed, at either enforcement point. */
export const REFUSING_VERDICTS: ReadonlySet<Verdict> = new Set<Verdict>([
  'DB_AHEAD',
  'DIVERGED',
  'IDENTITY_MISMATCH',
  'MIGRATION_FAILED',
  'SCHEMA_INCOMPLETE',
]);

export function buildReport(input: CompatInput): CompatReport {
  const { migrations, hasMigrationsTable, appliedRows, populated, stamp } =
    input;
  const identity = evaluateIdentity(
    stamp,
    input.configuredDeploymentId,
    input.stampCorrupt
  );

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
        // `sql()` returns null when the migration.sql file is absent — a
        // legitimately missing migration. It can also THROW (EACCES, EISDIR,
        // EIO, and other read failures Task 1's fs-based implementation
        // doesn't itself guard against). A throw here must not propagate: this
        // report is what `db status` prints, and that command is specified to
        // always exit 0, precisely because it's the diagnostic an operator
        // reaches for when something is already wrong. So a read failure is
        // coerced into the same "unreadable" outcome as an absent file, and
        // fails CLOSED the same way: BLOCKING, never silently treated as an
        // empty (and therefore additive-looking) migration.
        let sql: string | null;
        try {
          sql = migrations.sql(name);
        } catch {
          sql = null;
        }

        if (sql === null) {
          return {
            name,
            tier: 'BLOCKING' as const,
            hits: [
              {
                tier: 'BLOCKING' as const,
                rule: 'unreadable-migration',
                line: 1,
                // There is no statement to quote here — this is a message
                // describing the failure, not SQL. Task 4's renderer excerpts
                // `statement` as if it were SQL, so keep this readable as a
                // plain one-line message rather than SQL-shaped text.
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

  // Same precedence slot as the mismatch branch above: a stamp we cannot
  // read is at least as dangerous as one that names another deployment, and
  // must refuse rather than let the gate below treat it as "no stamp" and
  // adopt over it.
  if (identity.kind === 'corrupt') {
    return report(
      'IDENTITY_MISMATCH',
      'this database carries a deployment stamp that cannot be read, so its identity cannot be confirmed; refusing rather than overwriting it',
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

  // The migrations table itself is present but a core table is missing, so
  // the schema contradicts itself: this is neither a clean install nor a
  // consistent existing one. This does NOT require any applied rows — a
  // table left by an aborted setup, or one whose rows were all deliberately
  // rolled back, hits this branch just as much as a database with rows
  // genuinely applied, and the reason must not claim otherwise.
  // `populated === null` with no migrations table means "no history and no
  // data", handled by VIRGIN below — it's specifically the combination of
  // *having* the migrations table while population is undetermined that is
  // contradictory.
  if (populated === null && hasMigrationsTable) {
    return report(
      'SCHEMA_INCOMPLETE',
      'the migrations table is present but the users table is absent, so this database is inconsistent',
      null
    );
  }

  if (!hasMigrationsTable && (populated === false || populated === null)) {
    // `populated === null` here means no determination could be made about
    // data (the users table itself is missing), not that data was found and
    // counted as zero — the reason must say so rather than claiming "no
    // data" for a state that was never actually checked.
    const reason =
      populated === null
        ? 'no migration history and no users table — a fresh install'
        : 'no migration history and no data — a fresh install';
    return report('VIRGIN', reason, rollbackPossible);
  }

  if (pending.length > 0) {
    return report(
      'DB_BEHIND',
      `${pending.length} migration(s) pending`,
      rollbackPossible
    );
  }

  return report('EQUAL', 'the database matches this binary', null);
}
