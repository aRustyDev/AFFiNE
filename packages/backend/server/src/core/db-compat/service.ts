import { randomUUID } from 'node:crypto';

import { Injectable, Logger } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';

import {
  buildReport,
  type CompatReport,
  REFUSING_VERDICTS,
  type Verdict,
} from './compat';
import { readDbState } from './db-state';
import { adoptRequested, buildRef, configuredDeploymentId } from './env';
import {
  type AdoptionMode,
  type DeploymentStamp,
  readStamp,
  writeStamp,
} from './identity';
import { loadMigrationSet } from './migration-set';

export interface CompatDecision {
  report: CompatReport;
  ok: boolean;
  refusal: string | null;
  /** The adoption to record, or null when nothing needs recording. */
  adopt: AdoptionMode | null;
}

/**
 * Pure decision function over a report. Separated from the service so the whole
 * adoption gate is testable without a database.
 */
export function decide(
  report: CompatReport,
  options: { adopt: boolean }
): CompatDecision {
  const verdict: Verdict = report.verdict;

  if (REFUSING_VERDICTS.has(verdict)) {
    return { report, ok: false, refusal: report.reason, adopt: null };
  }

  // UNREADABLE is deliberately NOT in REFUSING_VERDICTS: the predeploy gate
  // refuses on it (below), but the boot guard logs and continues (design D9),
  // because refusing to boot over a packaging fault would take the fleet down
  // for a non-safety reason. `guard.ts` in Task 5 applies that asymmetry.
  if (verdict === 'UNREADABLE') {
    return { report, ok: false, refusal: report.reason, adopt: null };
  }

  const alreadyStamped = report.identity.kind !== 'absent';
  if (alreadyStamped) {
    return { report, ok: true, refusal: null, adopt: null };
  }

  if (verdict === 'VIRGIN') {
    return { report, ok: true, refusal: null, adopt: 'fresh-install' };
  }

  // Unstamped and populated: this is the adoption decision (design D3).
  const blocking = report.pending.filter(item => item.tier === 'BLOCKING');
  if (blocking.length > 0 && !options.adopt) {
    return {
      report,
      ok: false,
      refusal:
        `refusing to adopt a pre-existing database across ${blocking.length} CONTRACTING migration(s) ` +
        `(${blocking.map(item => item.name).join(', ')}) — applying them makes image rollback ` +
        `impossible. Confirm with AFFINE_DB_ADOPT=1 (or --adopt) once a VERIFIED-RESTORABLE ` +
        `backup exists.`,
      adopt: null,
    };
  }

  return {
    report,
    ok: true,
    refusal: null,
    adopt: options.adopt ? 'explicit' : 'implicit',
  };
}

@Injectable()
export class DbCompatService {
  private readonly logger = new Logger(DbCompatService.name);

  constructor(private readonly db: PrismaClient) {}

  async report(): Promise<CompatReport> {
    const migrations = loadMigrationSet();
    const state = await readDbState(this.db);
    const stamp = await readStamp(this.db);

    return buildReport({
      migrations,
      hasMigrationsTable: state.hasMigrationsTable,
      appliedRows: state.rows,
      populated: state.populated,
      stamp,
      configuredDeploymentId: configuredDeploymentId(),
    });
  }

  /**
   * Classify, and when `mutate` is set, record the adoption decision.
   * `mutate: false` is the read-only boot path.
   */
  async check(options: {
    mutate: boolean;
    adopt?: boolean;
  }): Promise<CompatDecision> {
    const report = await this.report();
    const decision = decide(report, {
      adopt: options.adopt ?? adoptRequested(),
    });

    if (decision.ok && decision.adopt && options.mutate) {
      await this.recordAdoption(decision.adopt);
    }

    return decision;
  }

  private async recordAdoption(mode: AdoptionMode): Promise<void> {
    const configured = configuredDeploymentId();
    const deploymentId = configured ?? randomUUID();
    const ref = buildRef();
    const now = new Date().toISOString();

    const stamp: DeploymentStamp = {
      deploymentId,
      adoptedAt: now,
      adoptionMode: mode,
      adoptedBy: ref,
      lastMigratedBy: { ...ref, at: now },
    };

    await writeStamp(this.db, stamp);

    if (mode === 'fresh-install') {
      this.logger.log(
        `initialized a fresh database as deployment ${deploymentId}`
      );
    } else {
      this.logger.warn(
        `ADOPTING pre-existing database (${mode}) as deployment ${deploymentId}`
      );
    }

    if (!configured) {
      this.logger.warn(
        `deployment identity minted as ${deploymentId}; set AFFINE_DEPLOYMENT_ID=${deploymentId} ` +
          `to enable wrong-database detection`
      );
    }
  }
}
