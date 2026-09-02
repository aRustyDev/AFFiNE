import { type INestApplicationContext, Logger } from '@nestjs/common';

import { bootGuardBypassed } from './env';
import { renderReport } from './render';
import { type CompatDecision, DbCompatService } from './service';

export class DatabaseIncompatibleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DatabaseIncompatibleError';
  }
}

/**
 * Pure enforcement, separated so it is testable without booting Nest.
 *
 * Keys on `decision.bootMayContinue` (D20), NOT on the verdict string. The
 * asymmetry it encodes: refusing to BOOT over a packaging fault would take the
 * fleet down for a non-safety reason, and because the migration initContainer
 * shares this pod and image, the predeploy gate has already refused in that
 * case (D9). Putting that judgement in a named field rather than a verdict
 * comparison means a future verdict inherits the right behaviour instead of
 * silently falling into "throw".
 */
export function enforce(
  decision: CompatDecision,
  context: { bypassed: boolean; logger: Pick<Logger, 'error' | 'log'> }
): void {
  const { report } = decision;

  // Minor A: a bypass left set is invisible until it is used. Log every time
  // it is armed — even when the decision would have been `ok` anyway — so an
  // operator who fixes the database and forgets to unset
  // AFFINE_DB_COMPAT_SKIP gets a standing signal rather than a silently
  // defanged guard.
  if (context.bypassed) {
    context.logger.error(
      `AFFINE_DB_COMPAT_SKIP is set — the boot guard is disabled (current verdict: ` +
        `${report.verdict}). This is an incident bypass, not a setting; unset it once resolved.`
    );
  }

  if (decision.ok) {
    return;
  }

  if (decision.bootMayContinue) {
    context.logger.error(
      `database compatibility could not be verified (${report.verdict}) — ` +
        `continuing, because "cannot verify" is not "verified bad". ` +
        `Reason: ${report.reason}`
    );
    return;
  }

  if (context.bypassed) {
    context.logger.error(
      `SUPPRESSING a ${report.verdict} refusal and starting anyway. Reason: ${decision.refusal}`
    );
    return;
  }

  // Important 1: the report is embedded in the THROWN message, not merely
  // logged. This is called from `server.ts` while Nest's logger still has
  // `bufferLogs: true` in effect — the buffer is only flushed inside
  // `app.listen()`'s callback, which a throw here prevents from ever running.
  // A log-only report would silently vanish, leaving only Node's raw
  // "uncaught exception" text. The thrown Error's message survives
  // regardless of logger state.
  const message = `refusing to start: ${decision.refusal}\n${renderReport(report)}`;
  context.logger.error(message);
  throw new DatabaseIncompatibleError(message);
}

/**
 * Runs the compatibility check and enforces it. Called from `server.ts`
 * between `NestFactory.create()` and `app.listen()` — strictly before every
 * module `onApplicationBootstrap` hook, including the native migration
 * runners in `BackendRuntimeProvider` and `StorageRuntimeProvider` that would
 * otherwise mutate an incompatible database before this guard ever ran.
 *
 * Kept here, rather than inlined in `server.ts`, so it stays unit-testable
 * without booting Nest.
 */
export async function assertDatabaseCompatible(
  app: Pick<INestApplicationContext, 'get'>,
  logger: Pick<Logger, 'error' | 'log'>
): Promise<void> {
  const bypassed = bootGuardBypassed();
  const service = app.get(DbCompatService);

  let decision: CompatDecision;
  try {
    // `check()` is pure since D17 — it writes nothing. Recording adoption is
    // `db stamp`'s job, run by the predeploy script after migrations; the
    // server must never stamp.
    decision = await service.check();
  } catch (error) {
    // Important 3: a crash here — an unreachable database, or a role lacking
    // SELECT on `_prisma_migrations` — happens before `enforce` is ever
    // called, so without this, AFFINE_DB_COMPAT_SKIP could never clear it and
    // an incident would crash-loop with no way out. Fail-closed stays the
    // default; the bypass exists specifically to end an incident.
    if (bypassed) {
      const reason = error instanceof Error ? error.message : String(error);
      logger.error(
        `AFFINE_DB_COMPAT_SKIP is set — SUPPRESSING a database compatibility check that ` +
          `crashed rather than returned a verdict, and starting anyway. Error: ${reason}`
      );
      return;
    }
    throw error;
  }

  enforce(decision, { bypassed, logger });
}
