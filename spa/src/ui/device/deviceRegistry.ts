// ============================================================================
//  deviceRegistry — which stations present as a DEVICE DRAWING
//  ---------------------------------------------------------------------------
//  Keyed by the station's keyboard family (keyboardProfiles.OS_FAMILY), not by
//  its id: a device drawing is a picture of the KEYBOARD a family shares, so a
//  second station on the same hardware (a 9500 beside the 9300) gets it by
//  joining the family. A family with a drawing replaces the station page's
//  letterboxed picture and toggleable on-screen keyboard with the drawing
//  (StreamView); every other station is untouched.
// ============================================================================

import { OS_FAMILY, type Family } from '../keyboard/keyboardProfiles';
import type { DeviceDrawing } from './deviceTypes';
import { NOKIA9300_DRAWING } from './nokia9300/drawing';

const DRAWINGS: Partial<Record<Family, DeviceDrawing>> = {
  nokia9300: NOKIA9300_DRAWING,
};

/** The device drawing this station presents as, or null for the default page. */
export function deviceDrawingFor(osId: string): DeviceDrawing | null {
  const family = OS_FAMILY[osId];
  return (family && DRAWINGS[family]) || null;
}
