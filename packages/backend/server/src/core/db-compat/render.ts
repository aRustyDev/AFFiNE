import type { CompatReport } from './compat';

const EXCERPT_WIDTH = 160;

/**
 * Trim a statement for display.
 *
 * `DdlHit.statement` carries the FULL collapsed statement — the classifier
 * deliberately does not truncate, because a blind head-slice can cut off the
 * very DDL that matched (measured: one corpus migration reports `retype-column`
 * while its first 160 chars show only `DROP COLUMN`s). Display width is this
 * module's concern, so keep the head but always say how much was dropped.
 */
function excerpt(statement: string): string {
  if (statement.length <= EXCERPT_WIDTH) {
    return statement;
  }
  const dropped = statement.length - EXCERPT_WIDTH;
  return `${statement.slice(0, EXCERPT_WIDTH)}… (+${dropped} chars)`;
}

/**
 * `VIRGIN` deserves different wording. On a fresh install every migration is
 * pending, and 17 of this repo's 117 are BLOCKING, so the computed answer is
 * always `false` — the renderer would print "rollback IMPOSSIBLE" on the one
 * path that is unambiguously safe. That is honest (an older image genuinely
 * cannot read the resulting schema) but alarming and useless, since there is no
 * prior deployment to roll back TO.
 */
function rollbackLine(report: CompatReport): string {
  if (report.verdict === 'VIRGIN') {
    return 'N/A (fresh install — nothing to roll back to)';
  }
  if (report.rollbackPossible === null) {
    return 'UNKNOWN';
  }
  return report.rollbackPossible ? 'POSSIBLE' : 'IMPOSSIBLE';
}

/**
 * All FIVE `IdentityState` arms. `corrupt` was added in T3 (D18) — a stamp row
 * that exists but cannot be parsed refuses rather than reading as absent, so it
 * must render as its own thing and never be confused with "not stamped".
 */
function identityLine(report: CompatReport): string {
  const identity = report.identity;
  switch (identity.kind) {
    case 'absent':
      return 'not stamped';
    case 'corrupt':
      return 'PRESENT BUT UNREADABLE — refusing rather than overwriting it';
    case 'unchecked':
      return `${identity.stamp.deploymentId} (unchecked — AFFINE_DEPLOYMENT_ID is not set)`;
    case 'match':
      return `${identity.stamp.deploymentId} (matches AFFINE_DEPLOYMENT_ID)`;
    case 'mismatch':
      return `${identity.stamp.deploymentId} != configured ${identity.configured}`;
  }
}

/**
 * `migrations applied:` is `applied.length` in the common case, but a
 * `MIGRATION_FAILED` report's half-applied migration appears in BOTH
 * `applied` (not rolled back) and `failed` (not finished) — see the doc on
 * `CompatReport.known`/`applied` in `compat.ts`. Printing a bare count would
 * read as "N migrations cleanly applied", which is false for that one; say so
 * explicitly rather than let the same name appear twice with no explanation.
 */
function appliedLine(report: CompatReport): string {
  if (report.failed.length > 0) {
    return `${report.applied.length} (${report.failed.length} unfinished)`;
  }
  return `${report.applied.length}`;
}

export interface RenderReportOptions {
  /**
   * Collapse the `pending` list to a bare count instead of every migration's
   * tier and DDL hits. Intended for `db check` on a decision that is `ok` and
   * `VIRGIN`: a fresh install has every migration pending — 117 of them, many
   * BLOCKING — and full detail there is 261 lines of noise on the one path
   * that is unambiguously safe, drowning the initContainer log on the run
   * where it matters least. `db status` and every refusal keep full detail,
   * where it is the evidence an operator needs.
   */
  summarizePending?: boolean;
}

export function renderReport(
  report: CompatReport,
  options: RenderReportOptions = {}
): string {
  // `UNREADABLE` means the migration set itself could not be loaded: `known`
  // is `[]`, which makes `ahead` (computed as "applied but not known")
  // contain EVERY applied migration. Rendered plainly that reads as "this
  // database was migrated by a far newer binary" — the opposite of the truth,
  // "this binary could not find its own migrations directory". See the doc on
  // `CompatReport.known` in `compat.ts`: a renderer must suppress these lists
  // for this verdict rather than print them.
  if (report.verdict === 'UNREADABLE') {
    return [
      `verdict:                  ${report.verdict}`,
      `reason:                   ${report.reason}`,
      `migrations known:         unknown (migration set could not be read)`,
      `identity:                 ${identityLine(report)}`,
    ].join('\n');
  }

  const lines: string[] = [
    `verdict:                  ${report.verdict}`,
    `reason:                   ${report.reason}`,
    `migrations known:         ${report.known.length}`,
    `migrations applied:       ${appliedLine(report)}`,
    `identity:                 ${identityLine(report)}`,
    `rollback after applying:  ${rollbackLine(report)}`,
  ];

  if (report.ahead.length > 0) {
    lines.push(
      '',
      `in database but NOT in this binary (${report.ahead.length}):`
    );
    for (const name of report.ahead) {
      lines.push(`  ${name}`);
    }
  }

  if (report.failed.length > 0) {
    lines.push('', `unfinished, not rolled back (${report.failed.length}):`);
    for (const name of report.failed) {
      lines.push(`  ${name}`);
    }
  }

  if (report.pending.length > 0) {
    lines.push('', `pending (${report.pending.length}):`);
    if (options.summarizePending) {
      lines.push('  detail omitted — pass without summarizePending to see it');
    } else {
      for (const item of report.pending) {
        lines.push(`  ${item.tier.padEnd(11)} ${item.name}`);
        for (const hit of item.hits) {
          lines.push(`    L${hit.line} ${hit.rule}: ${excerpt(hit.statement)}`);
        }
      }
    }
  }

  return lines.join('\n');
}
