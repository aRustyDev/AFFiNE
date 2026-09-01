import { Logger } from '@nestjs/common';

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

const logger = new Logger('DbCompatEnv');

/**
 * Trims and lowercases before comparing — the same class of input as
 * `AFFINE_DEPLOYMENT_ID` (a trailing newline is routine from a mounted
 * secret file or a Helm block scalar) but with the opposite failure mode: a
 * boolean knob that fails to parse fails CLOSED (`false`), not open. For
 * `AFFINE_DB_COMPAT_SKIP`, the incident bypass, "closed" means the fleet
 * stays down during the very outage the bypass exists to end — so an
 * unrecognised non-empty value (e.g. `=yes`) is logged at WARN rather than
 * silently swallowed.
 */
function flag(name: string): boolean {
  const raw = process.env[name];
  if (raw === undefined) {
    return false;
  }
  const value = raw.trim().toLowerCase();
  if (value === '') {
    return false;
  }
  if (value === '1' || value === 'true') {
    return true;
  }
  if (value === '0' || value === 'false') {
    return false;
  }
  logger.warn(
    `${name}=${JSON.stringify(raw)} is not a recognised boolean value (expected 1/true or 0/false); treating as unset`
  );
  return false;
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
