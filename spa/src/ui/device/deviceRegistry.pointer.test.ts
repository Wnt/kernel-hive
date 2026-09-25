// M-UI4: the `pointer: 'none'` flag (deviceTypes.ts) on a device drawing —
// the real Nokia 9300 has no mouse, pen or touch digitizer, so the SPA must
// never forward a stream click/drag/wheel to the guest for it. The flag is
// declared once on the drawing and reached through the KEYBOARD FAMILY
// (deviceRegistry.ts), so any station that joins the nokia9300 family
// (keyboardProfiles.ts) inherits it without a drawing of its own.
import { describe, expect, it } from 'vitest';
import { deviceDrawingFor } from './deviceRegistry';
import { NOKIA9300_DRAWING } from './nokia9300/drawing';

describe('nokia9300 device drawing: pointer: none', () => {
  it('declares no pointer on the drawing itself', () => {
    expect(NOKIA9300_DRAWING.pointer).toBe('none');
  });

  it('applies to nokia9300 by station id', () => {
    expect(deviceDrawingFor('nokia9300')?.pointer).toBe('none');
  });

  it('a station with no device drawing has nothing to check (null, not a crash)', () => {
    expect(deviceDrawingFor('some-unknown-station-id')).toBeNull();
  });
});
