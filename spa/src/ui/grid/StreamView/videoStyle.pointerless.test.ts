// M-UI4: the stream element must not show a pointer-capture cursor
// (S.video's `cursor: 'crosshair'`) on a device-drawing station that has no
// guest pointer at all (`pointer: 'none'`) — the cursor would advertise an
// interaction that never reaches the guest.
import { describe, expect, it } from 'vitest';
import { videoStyleFor } from './videoStyle';

describe('videoStyleFor: pointerless cursor override', () => {
  it('shows the crosshair pointer-capture cursor by default', () => {
    const style = videoStyleFor({ nativeWidth: 1024, zoom: { s: 1, x: 0, y: 0, animated: false }, present: null });
    expect(style.cursor).toBe('crosshair');
  });

  it('shows the plain default cursor when pointerless is true', () => {
    const style = videoStyleFor({
      nativeWidth: 1024, zoom: { s: 1, x: 0, y: 0, animated: false }, present: null, pointerless: true,
    });
    expect(style.cursor).toBe('default');
  });

  it('the pointerless override survives the pixelated (low-res) branch too', () => {
    const style = videoStyleFor({
      nativeWidth: 320, zoom: { s: 1, x: 0, y: 0, animated: false }, present: null, pointerless: true,
    });
    expect(style.cursor).toBe('default');
  });
});
