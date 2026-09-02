import { Module } from '@nestjs/common';

import { DbCompatService } from './service';

/**
 * Service only — safe to import anywhere, including the minimal CLI context.
 *
 * The boot check (`assertDatabaseCompatible` in `guard.ts`) is NOT wired
 * through a module at all (design D10/D14, strengthened in `affine-tc6.5`
 * review): it runs in `server.ts` between `NestFactory.create()` and
 * `app.listen()`, before any module's `onApplicationBootstrap` hook and
 * therefore structurally unreachable from the CLI, which dispatches via
 * `src/index.ts` to `runCli()` and never touches `server.ts`. An earlier
 * version of this file added a `DbCompatGuardModule` running the check from
 * an `OnApplicationBootstrap` hook on `AppModule`; that hook lost a race
 * against `BackendRuntimeProvider` and `StorageRuntimeProvider`, both of
 * which run native migrations from their own bootstrap hooks and sit earlier
 * in Nest's hook order — the guard could never refuse in time. Hoisting the
 * check out of the module graph entirely fixes that by construction.
 */
@Module({
  providers: [DbCompatService],
  exports: [DbCompatService],
})
export class DbCompatModule {}

export { classifyDdl, type DdlTier } from './classify';
export { type CompatReport, type Verdict } from './compat';
export { assertDatabaseCompatible, DatabaseIncompatibleError } from './guard';
export { renderReport } from './render';
export { type CompatDecision, DbCompatService } from './service';
