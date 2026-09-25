// The open Nokia 9300 Communicator as a device drawing (see deviceTypes.ts).
import type { DeviceDrawing } from '../deviceTypes';
import { NOKIA9300_KEYS, NOKIA9300_MODS, SCREEN, VIEW_H, VIEW_W } from './keys';
import { Nokia9300Outline } from './Outline';

export const NOKIA9300_DRAWING: DeviceDrawing = {
  id: 'nokia9300-open',
  name: 'Nokia 9300 Communicator, open',
  viewBox: { w: VIEW_W, h: VIEW_H },
  screen: SCREEN,
  keys: NOKIA9300_KEYS,
  mods: NOKIA9300_MODS,
  Outline: Nokia9300Outline,
  shortcutNote:
    'Press the drawn keys, or type: F1–F4 command buttons · F5–F12 Desk … My own · '
    + 'arrows and Enter steer · Right Alt is Chr · the Menu key is Menu',
};
