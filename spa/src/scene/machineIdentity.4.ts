// GENERATED shard 4/4 of EXHIBIT_IDENTITIES — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./machineIdentity.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { ExhibitIdentity } from './machineIdentity';

export const EXHIBIT_IDENTITIES_4 = {
  // SymbOS: Philips MSX2 hardware running explicitly later software.
  symbos: {
    caseTint: '#cdc7b6', accentTint: '#376ca8', tintMix: 0.4,
    badge: 'PHILIPS NMS 8250', spec: 'Z80 • 512K • SYMBOS 2025', kit: 'eightBit',
  },
} as const satisfies Record<string, ExhibitIdentity>;
