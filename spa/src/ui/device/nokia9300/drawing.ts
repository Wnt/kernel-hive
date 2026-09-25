// The open Nokia 9300 Communicator as a device drawing (see deviceTypes.ts).
import type { DeviceDrawing } from '../deviceTypes';
import { NOKIA9300_KEYS, NOKIA9300_MODS, SCREEN, VIEW_H, VIEW_W } from './keys';
import { Nokia9300Outline } from './Outline';

export const NOKIA9300_DRAWING: DeviceDrawing = {
  id: 'nokia9300-open',
  name: 'Nokia 9300 Communicator, open',
  viewBox: { w: VIEW_W, h: VIEW_H },
  // The real 9300 has no mouse, pen or touch digitizer — Desk and every other
  // app ignore a pointer entirely (Z4 B's pointer wall, $J/Z4/B/REPORT.md).
  // The drawn keys and the physical keyboard are the only input.
  pointer: 'none',
  screen: SCREEN,
  keys: NOKIA9300_KEYS,
  mods: NOKIA9300_MODS,
  Outline: Nokia9300Outline,
};
