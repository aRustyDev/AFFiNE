import { Module } from '@nestjs/common';

import { DbCompatGuard } from './guard';
import { DbCompatService } from './service';

/**
 * Service only — safe to import anywhere, including the minimal CLI context.
 *
 * The boot guard deliberately lives in a SEPARATE module added in Task 5
 * (`DbCompatGuardModule`), which only `AppModule` may import. See design
 * D10/D14: the CLI imports `FunctionalityModules`, so a guard reachable from
 * there would make `db check` refuse to run in exactly the situation it exists
 * for.
 */
@Module({
  providers: [DbCompatService],
  exports: [DbCompatService],
})
export class DbCompatModule {}

/**
 * Adds the boot guard. ONLY `AppModule` may import this (design D10/D14): the
 * CLI imports `FunctionalityModules`, and a guard reachable from there would
 * make `db check` refuse to run in exactly the situation it exists for.
 */
@Module({
  imports: [DbCompatModule],
  providers: [DbCompatGuard],
})
export class DbCompatGuardModule {}

export { classifyDdl, type DdlTier } from './classify';
export { type CompatReport, type Verdict } from './compat';
export { renderReport } from './render';
export { type CompatDecision, DbCompatService } from './service';
