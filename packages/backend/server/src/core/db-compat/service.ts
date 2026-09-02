import { randomUUID } from 'node:crypto';

import { Injectable, Logger } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';

import { buildReport, type CompatReport, type Verdict } from './compat';
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
  /**
   * True whenever the boot guard may continue past this decision: every
   * `ok: true` result (nothing to refuse), and — uniquely among refusals —
   * `UNREADABLE`. The predeploy gate (`db check`) still treats `UNREADABLE`
   * as `ok: false` and won't mutate past it, but design D9 requires the
   * BOOT guard specifically to log and continue rather than take the whole
   * fleet down over what might be a packaging fault rather than a genuine
   * compatibility problem. Every other refusal (any REFUSING_VERDICTS
   * verdict, or the BLOCKING-pending-without-flag refusal) means `false`:
   * the boot guard must not continue past those. Callers should read this
   * field rather than re-deriving the asymmetry from `report.verdict`
   * themselves.
   */
  bootMayContinue: boolean;
}

type VerdictDisposition =
  | 'refuse' // compat.ts's REFUSING_VERDICTS: never proceeds, at either enforcement point.
  | 'boot-may-continue-refuse' // UNREADABLE only: refuses to mutate, but the boot guard may continue (design D9).
  | 'proceed'; // Reaches the adopt decision below.

/**
 * Minor 2: every member of `Verdict` must appear here. Typing this as
 * `Record<Verdict, ...>` makes it a COMPILE-TIME exhaustiveness check — a
 * tenth verdict added to the `Verdict` union without a disposition here
 * fails to compile (TS2739: missing properties), rather than silently
 * falling through to the `proceed` path with `ok: true`. A ninth verdict
 * (`SCHEMA_INCOMPLETE`) was added mid-flight in an earlier task, so this is
 * not hypothetical. A test in service.spec.ts cross-checks this stays
 * consistent with `REFUSING_VERDICTS`, the canonical list other consumers
 * read.
 */
const VERDICT_DISPOSITION: Record<Verdict, VerdictDisposition> = {
  DB_AHEAD: 'refuse',
  DIVERGED: 'refuse',
  IDENTITY_MISMATCH: 'refuse',
  MIGRATION_FAILED: 'refuse',
  SCHEMA_INCOMPLETE: 'refuse',
  UNREADABLE: 'boot-may-continue-refuse',
  VIRGIN: 'proceed',
  EQUAL: 'proceed',
  DB_BEHIND: 'proceed',
};

/**
 * Pure decision function over a report. Separated from the service so the whole
 * adoption gate is testable without a database.
 */
export function decide(
  report: CompatReport,
  options: { adopt: boolean }
): CompatDecision {
  const verdict: Verdict = report.verdict;
  const disposition = VERDICT_DISPOSITION[verdict];

  if (disposition === 'refuse') {
    return {
      report,
      ok: false,
      refusal: report.reason,
      adopt: null,
      bootMayContinue: false,
    };
  }

  // UNREADABLE is deliberately NOT in REFUSING_VERDICTS: the predeploy gate
  // refuses on it (below), but the boot guard logs and continues (design D9),
  // because refusing to boot over a packaging fault would take the fleet down
  // for a non-safety reason. `guard.ts` in Task 5 reads `bootMayContinue`
  // rather than re-deriving this from `report.verdict` itself.
  if (disposition === 'boot-may-continue-refuse') {
    return {
      report,
      ok: false,
      refusal: report.reason,
      adopt: null,
      bootMayContinue: true,
    };
  }

  // disposition === 'proceed': VIRGIN | EQUAL | DB_BEHIND.

  // Minor 3: an explicit allow-list, not `!== 'absent'`. `IdentityState`
  // also has `mismatch` and `corrupt` arms; both always force a `refuse`
  // disposition above (compat.ts maps them to IDENTITY_MISMATCH), so in
  // practice neither ever reaches here — but that safety was emergent
  // across two files. This makes it local: only `unchecked`/`match` (a
  // stamp exists and was evaluated as fine) count as "already adopted,
  // nothing to do".
  const alreadyStamped =
    report.identity.kind === 'unchecked' || report.identity.kind === 'match';
  if (alreadyStamped) {
    return {
      report,
      ok: true,
      refusal: null,
      adopt: null,
      bootMayContinue: true,
    };
  }

  // Important 1 (second re-review): the BLOCKING gate runs BEFORE the
  // fresh-install return below, and fires for every non-VIRGIN verdict
  // regardless of `report.populated` — it is NOT gated on `populated`
  // being right. `populated` is a real Postgres read (`db-state.ts`) that
  // could in principle be miscomputed; the gate that exists specifically
  // to prevent an unrecoverable migration from running unattended must not
  // have its firing depend on that read being correct. `VIRGIN` is the one
  // exception: a virgin database has EVERY migration pending, several of
  // them BLOCKING, and gating a fresh install on that would be absurd —
  // and a genuinely fresh post-migrate install always has `pending: []` by
  // construction (`prisma migrate deploy` applies everything the binary
  // knows), so this is a no-op there regardless of `populated`.
  const blocking = report.pending.filter(item => item.tier === 'BLOCKING');
  if (verdict !== 'VIRGIN' && blocking.length > 0 && !options.adopt) {
    return {
      report,
      ok: false,
      refusal:
        `refusing to adopt a pre-existing database across ${blocking.length} CONTRACTING migration(s) ` +
        `(${blocking.map(item => item.name).join(', ')}) — applying them makes image rollback ` +
        `impossible. Confirm with AFFINE_DB_ADOPT=1 (or --adopt) once a VERIFIED-RESTORABLE ` +
        `backup exists.`,
      adopt: null,
      bootMayContinue: false,
    };
  }

  // Unstamped and with no data: a fresh install, whether or not the schema
  // has been fully migrated yet. `VIRGIN` covers "before `prisma migrate
  // deploy`"; `populated: false` on an otherwise EQUAL/DB_BEHIND report
  // covers "after migrate but before anyone has created a workspace" —
  // exactly the state `db stamp` runs in right after a brand-new
  // deployment's first migration pass. Neither should ever be logged as
  // "adopting a pre-existing database": there is nothing to adopt.
  if (verdict === 'VIRGIN' || report.populated === false) {
    return {
      report,
      ok: true,
      refusal: null,
      adopt: 'fresh-install',
      bootMayContinue: true,
    };
  }

  // Unstamped and populated, with nothing BLOCKING pending (or the flag was
  // given): this is the adoption decision (design D3).
  return {
    report,
    ok: true,
    refusal: null,
    adopt: options.adopt ? 'explicit' : 'implicit',
    bootMayContinue: true,
  };
}

@Injectable()
export class DbCompatService {
  private readonly logger = new Logger(DbCompatService.name);

  constructor(private readonly db: PrismaClient) {}

  /**
   * Assembles a compatibility report. Never throws on a missing
   * `app_configs` table — that is the normal state of a fresh install before
   * `prisma migrate deploy` has run, and `readStamp` degrades it to "no
   * stamp" (see `identity.ts`).
   */
  async report(): Promise<CompatReport> {
    const migrations = loadMigrationSet();
    const state = await readDbState(this.db);
    const { stamp, corrupt } = await readStamp(this.db);

    return buildReport({
      migrations,
      hasMigrationsTable: state.hasMigrationsTable,
      appliedRows: state.rows,
      populated: state.populated,
      stamp,
      stampCorrupt: corrupt,
      configuredDeploymentId: configuredDeploymentId(),
    });
  }

  /**
   * Classify and decide. Writes nothing — this is the predeploy gate
   * (`db check`), which must be able to refuse BEFORE anything mutates,
   * including before `prisma migrate deploy` has even run and `app_configs`
   * necessarily exists yet.
   *
   * New predeploy order:
   *   fixFailedMigrations() → db check (this method; refuses up front)
   *                         → prisma migrate deploy → data migrations
   *                         → db stamp (`stamp()`; app_configs now exists)
   */
  async check(options: { adopt?: boolean } = {}): Promise<CompatDecision> {
    const report = await this.report();
    return decide(report, {
      adopt: options.adopt === true || adoptRequested(),
    });
  }

  /**
   * Records the adoption decision. Idempotent, and intended to run AFTER
   * migrations, once `app_configs` is guaranteed to exist:
   *
   * - No stamp yet: records the adoption `check()` would decide (fresh
   *   install, implicit, or explicit).
   * - Already stamped: updates ONLY `lastMigratedBy` — `adoptedAt` and
   *   `adoptionMode` describe the ORIGINAL adoption and must never be
   *   overwritten by a later migration run.
   * - Current verdict refuses (e.g. `IDENTITY_MISMATCH`, a corrupt stamp, a
   *   BLOCKING migration without the flag): does not stamp. Logs and
   *   returns — by the time this runs, migrations may already have applied,
   *   so there is no meaningful "abort" left to perform here; the refusal
   *   that matters is the one `check()` raised before migrations ran.
   */
  async stamp(): Promise<void> {
    const report = await this.report();
    const decision = decide(report, { adopt: adoptRequested() });

    if (!decision.ok) {
      this.logger.error(
        `refusing to record deployment stamp: ${decision.refusal}`
      );
      return;
    }

    if (
      report.identity.kind === 'unchecked' ||
      report.identity.kind === 'match'
    ) {
      await this.touchLastMigratedBy(report.identity.stamp);
      return;
    }

    if (decision.adopt) {
      await this.recordAdoption(decision.adopt);
    }
  }

  private async touchLastMigratedBy(stamp: DeploymentStamp): Promise<void> {
    await writeStamp(this.db, {
      ...stamp,
      lastMigratedBy: { ...buildRef(), at: new Date().toISOString() },
    });
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
