/**
 * `app_configs` id for the deployment stamp.
 *
 * The `$` prefix is deliberate and load-bearing. `ServerService.loadDbOverrides()`
 * merges every `app_configs` row into the runtime config tree, but `override()`
 * ignores unknown config modules — so an id whose first segment can never match
 * a registered module name is inert. See grounding G3 and design D6. Do not
 * change this to a dotted, module-shaped id.
 */
export const DEPLOYMENT_STAMP_ID = '$deployment';

export type AdoptionMode = 'fresh-install' | 'implicit' | 'explicit';

export interface BuildRef {
  version: string;
  buildSha: string;
}

export interface DeploymentStamp {
  deploymentId: string;
  adoptedAt: string;
  adoptionMode: AdoptionMode;
  adoptedBy: BuildRef;
  lastMigratedBy?: BuildRef & { at: string };
}

export type IdentityState =
  | { kind: 'absent' }
  | { kind: 'unchecked'; stamp: DeploymentStamp }
  | { kind: 'match'; stamp: DeploymentStamp }
  | { kind: 'mismatch'; stamp: DeploymentStamp; configured: string };

export function evaluateIdentity(
  stamp: DeploymentStamp | null,
  configured: string | null
): IdentityState {
  if (!stamp) {
    return { kind: 'absent' };
  }
  if (!configured) {
    return { kind: 'unchecked', stamp };
  }
  return stamp.deploymentId === configured
    ? { kind: 'match', stamp }
    : { kind: 'mismatch', stamp, configured };
}
