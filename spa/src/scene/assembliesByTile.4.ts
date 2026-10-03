// GENERATED shard 4/4 of ASSEMBLIES_BY_TILE — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./assembliesByTile.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { Assembly } from './machines';

export const ASSEMBLIES_BY_TILE_4 = {
  svi728: {
    kind: 'homeMicro', body: 'pizzaBoxC', monitor: 'homeCrtB',
  },
  svi738: {
    kind: 'homeMicro', body: 'pizzaBoxC', monitor: 'homeCrtE',
  },
  symbos: {
    kind: 'pizzaBox', body: 'pizzaBoxB', monitor: 'homeCrtD',
    mouse: 'paramMouseA',
  },
} as const satisfies Record<string, Assembly>;
