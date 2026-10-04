// GENERATED shard 4/4 of EXHIBIT_IDENTITIES — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./machineIdentity.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { ExhibitIdentity } from './machineIdentity';

export const EXHIBIT_IDENTITIES_4 = {
  svi728: {
    caseTint: '#cdc7b6', accentTint: '#2b2a29', tintMix: 0.46,
    badge: 'SPECTRAVIDEO SVI-728', spec: 'Z80 • 1984', kit: 'eightBit',
  },
  svi738: {
    caseTint: '#cdc7b6', accentTint: '#2b2a29', tintMix: 0.46,
    badge: 'SPECTRAVIDEO SVI-738', spec: 'Z80 • 1985', kit: 'eightBit',
  },
  // SymbOS: Philips MSX2 hardware running explicitly later software.
  symbos: {
    caseTint: '#cdc7b6', accentTint: '#376ca8', tintMix: 0.4,
    badge: 'PHILIPS NMS 8250', spec: 'Z80 • 512K • SYMBOS 2025', kit: 'eightBit',
  },
  // The same brown breadbin as c64; the accent is the BASIC screen's own light
  // blue (VIC-II colour 14), which is also the station's registry accent.
  c64basic: {
    caseTint: '#8b6746', accentTint: '#6c5eb5', tintMix: 0.45,
    badge: 'COMMODORE 64', spec: 'BASIC V2 • 1982', kit: 'eightBit',
  },
} as const satisfies Record<string, ExhibitIdentity>;
