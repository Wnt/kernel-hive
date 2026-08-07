import { describe, expect, it } from 'vitest';
import type { HallLayout } from './hallLayout';
import { hallLightmapsEnabled } from './hallLightmaps';

function layout(width = 12.8, depth = 19): HallLayout {
  return {
    count: 37,
    dims: { width, depth, height: 2.8, tileStripDepth: 1.6 },
    columns: 6,
    sections: [],
    desks: [],
    troffers: [],
    windows: [],
    eraMarkers: [],
    props: [],
    railSpec: { loop: [], look: [] },
  };
}

describe('hallLightmapsEnabled', () => {
  it('enables the production bake by default', () => {
    expect(hallLightmapsEnabled(layout(), '')).toBe(true);
  });

  it('supports the A/B query toggle', () => {
    expect(hallLightmapsEnabled(layout(), '?bakedLight=0')).toBe(false);
    expect(hallLightmapsEnabled(layout(), '?bakedLight=false')).toBe(false);
  });

  it('skips lightmaps when layout dimensions change', () => {
    expect(hallLightmapsEnabled(layout(12.8, 22.3), '?hallTest=50')).toBe(false);
  });
});
