// Scene-v2 dimensional vocabulary. Layout-dependent values live in
// hallLayout.ts; these constants are the real-world modules they are built from.

export const CEILING_HEIGHT = 2.8;
export const CEILING_GRID_MODULE = 0.6;

export const DESK_MODULE = {
  width: 1.6,
  depth: 0.82,
  height: 0.72,
  top: 0.04,
} as const;

export const TROFFER_SIZE = [1.2, 0.6] as const;

export const PALETTE = {
  carpet: '#4f5a63',
  tileFloor: '#b4b2ad',
  wall: '#f2efe9',
  pine: '#c8933f',
  pineDark: '#8a5a28',
  ceiling: '#e8e6e0',
  ceilingGrid: '#cfccc4',
  deskTop: '#d1a86b',
  deskLeg: '#b9bcbe',
  dustCover: '#e8e2d5',
  placard: '#fdfdfb',
} as const;
