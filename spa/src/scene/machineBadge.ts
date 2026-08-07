import type { Assembly } from './machines';

export type IdentityBadgeSurface = 'case' | 'bezel' | 'dock';

export function identityBadgeSurface(
  assembly: Assembly,
): IdentityBadgeSurface | null {
  if (assembly.kind === 'phoneDock') return assembly.body ? 'dock' : null;
  if (
    assembly.kind === 'towerSetup'
    || assembly.kind === 'pizzaBox'
    || assembly.kind === 'homeMicro'
    || assembly.kind === 'industrial'
  ) {
    if (assembly.body) return 'case';
    return assembly.monitor ? 'bezel' : null;
  }
  if (assembly.kind === 'combo') return assembly.combo ? 'bezel' : null;
  if (assembly.kind === 'allInOne' || assembly.kind === 'terminal') {
    return assembly.body ? 'bezel' : null;
  }
  return null;
}
