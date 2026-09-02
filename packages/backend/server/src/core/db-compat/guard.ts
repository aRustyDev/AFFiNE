import {
  Injectable,
  Logger,
  type OnApplicationBootstrap,
} from '@nestjs/common';

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
      `AFFINE_DB_COMPAT_SKIP is set — SUPPRESSING a ${report.verdict} refusal and starting ` +
        `anyway. This is an incident bypass, not a setting; unset it once resolved. ` +
        `Reason: ${decision.refusal}`
    );
    return;
  }

  context.logger.error(
    `refusing to start: ${decision.refusal}\n${renderReport(report)}`
  );
  throw new DatabaseIncompatibleError(`refusing to start: ${decision.refusal}`);
}

@Injectable()
export class DbCompatGuard implements OnApplicationBootstrap {
  private readonly logger = new Logger(DbCompatGuard.name);

  constructor(private readonly service: DbCompatService) {}

  async onApplicationBootstrap(): Promise<void> {
    // Seven existing test files import AppModule and call module.init(), which
    // runs bootstrap hooks. The guard has its own unit tests; running it there
    // would add a database query and a failure mode to all of them.
    if (env.testing) {
      return;
    }

    // `check()` is pure since D17 — it writes nothing. Recording adoption is
    // `db stamp`'s job, run by the predeploy script after migrations; the
    // server must never stamp.
    const decision = await this.service.check();

    enforce(decision, { bypassed: bootGuardBypassed(), logger: this.logger });
  }
}
