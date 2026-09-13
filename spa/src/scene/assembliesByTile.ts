// =====================================================================  },
//  ASSEMBLIES_BY_TILE — split out of machines.ts (ts-src 600-line hard cap).
//  ---------------------------------------------------------------------------
//  Isolating this table also removes a recurring merge hazard: every new
//  tile appends to ASSEMBLIES_BY_TILE at the same spot, so two parallel tile
//  branches conflicted here on every merge while it lived inside the far
//  busier machines.ts. See machines.ts for MachineModel/MODELS, the
//  AssemblyKind/Assembly types, and assemblyForTile/hasIntegratedKeyboard.
// =====================================================================  },

import type { Assembly } from './machines';
import { ASSEMBLIES_BY_TILE_1 } from './assembliesByTile.1';
import { ASSEMBLIES_BY_TILE_2 } from './assembliesByTile.2';
import { ASSEMBLIES_BY_TILE_3 } from './assembliesByTile.3';

// Every registry lineup entry is bound explicitly. Keep entries that do not
// fit in today's 22 slots here so a future hall expansion requires no modeling
// fallback or index-cycle changes.
export const ASSEMBLIES_BY_TILE = {
  ...ASSEMBLIES_BY_TILE_1,
  ...ASSEMBLIES_BY_TILE_2,
  ...ASSEMBLIES_BY_TILE_3,
} as const satisfies Record<string, Assembly>;

