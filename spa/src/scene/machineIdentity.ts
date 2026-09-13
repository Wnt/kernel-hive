import type { ASSEMBLIES_BY_TILE } from './machines';
import { EXHIBIT_IDENTITIES_1 } from './machineIdentity.1';
import { EXHIBIT_IDENTITIES_2 } from './machineIdentity.2';
import { EXHIBIT_IDENTITIES_3 } from './machineIdentity.3';

type StationKit = 'eightBit' | 'office90' | 'workstation' | 'modern' | 'mobile';

export interface ExhibitIdentity {
  caseTint: `#${string}`;
  accentTint: `#${string}`;
  /** Existing baked color remains dominant; this is a restrained exhibit finish shift. */
  tintMix: number;
  badge: string;
  spec?: string;
  kit: StationKit;
}

/**
 * Binding exhibit-finish table. Hardware names and era cues come from
 * HARDWARE-MATRIX.md; badges intentionally omit protected logos/trade dress.
 */
export const EXHIBIT_IDENTITIES = {
  ...EXHIBIT_IDENTITIES_1,
  ...EXHIBIT_IDENTITIES_2,
  ...EXHIBIT_IDENTITIES_3,
} as const satisfies Record<keyof typeof ASSEMBLIES_BY_TILE, ExhibitIdentity>;

const FALLBACK_IDENTITY: ExhibitIdentity = {
  caseTint: '#bdb6a5',
  accentTint: '#666c6c',
  tintMix: 0.2,
  badge: 'COMPUTER',
  kit: 'workstation',
};

export function identityForTile(tileId: string): ExhibitIdentity {
  return EXHIBIT_IDENTITIES[tileId as keyof typeof EXHIBIT_IDENTITIES]
    ?? FALLBACK_IDENTITY;
}
