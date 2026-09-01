/**
 * These three knobs are read from `process.env` DIRECTLY and are deliberately
 * NOT registered with `defineModuleConfig` (design D13).
 *
 * A config item with an `env:` binding is also overridable from the
 * `app_configs` table. For a safety control that is backwards: a database row
 * could switch off the guard whose whole job is to judge that database. Direct
 * env reads also keep the boot guard independent of config load order.
 *
 * Consequence, intended: these do not appear in the admin UI and cannot be
 * changed at runtime.
 */

function flag(name: string): boolean {
  const value = process.env[name];
  return value === '1' || value?.toLowerCase() === 'true';
}

/** Externally-asserted deployment identity. Without it, identity is unchecked. */
export function configuredDeploymentId(): string | null {
  const value = process.env.AFFINE_DEPLOYMENT_ID?.trim();
  return value ? value : null;
}

/** Operator asserts a pre-existing database is intended, even across a contract. */
export function adoptRequested(): boolean {
  return flag('AFFINE_DB_ADOPT');
}

/**
 * Incident bypass. Skips the BOOT guard only — never the predeploy gate — and
 * every skipped boot logs at ERROR (design D11).
 */
export function bootGuardBypassed(): boolean {
  return flag('AFFINE_DB_COMPAT_SKIP');
}

export function buildRef(): { version: string; buildSha: string } {
  return {
    version: env.version,
    buildSha: process.env.GITHUB_SHA ?? 'unknown',
  };
}
