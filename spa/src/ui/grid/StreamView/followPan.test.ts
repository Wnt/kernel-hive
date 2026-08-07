// Unit coverage for the edge-follow pan: a zoomed view must chase the trackpad
// crosshair rather than let it walk off screen, without ever sliding the picture
// further than the pinch layer would allow.
import { describe, expect, it } from 'vitest';
import { followPan } from './followPan';

const box = { w: 400, h: 800 };

describe('followPan — keep the crosshair on screen', () => {
  it('does nothing while the whole picture is visible', () => {
    expect(followPan({ px: -50, py: -50, ...box, s: 1, x: 0, y: 0 })).toBeNull();
  });

  it('does nothing while the crosshair is comfortably inside', () => {
    expect(followPan({ px: 200, py: 400, ...box, s: 2, x: 0, y: 0 })).toBeNull();
  });

  it('pans just enough to put a crosshair past the LEFT edge back on the margin', () => {
    // px 10 is 18 short of the 28 px margin → the view slides 18 px right.
    expect(followPan({ px: 10, py: 400, ...box, s: 2, x: 0, y: 0 })).toEqual({ x: 18, y: 0 });
  });

  it('…and the same on the bottom edge', () => {
    // py 790 is 18 past (800 - 28) → the view slides 18 px up.
    expect(followPan({ px: 200, py: 790, ...box, s: 2, x: 0, y: 0 })).toEqual({ x: 0, y: -18 });
  });

  it('never pans past the picture — the pinch layer’s own bound', () => {
    // At 2x the pan limit is (s-1)*w/2 = 200; a demand for more is clamped there.
    expect(followPan({ px: -5000, py: 400, ...box, s: 2, x: 0, y: 0 })).toEqual({ x: 200, y: 0 });
  });

  it('reports null rather than a no-op pan when it is already at the limit', () => {
    // Already hard against the left bound: nothing more to give, so the sprite
    // loop must not re-commit the same transform every frame.
    expect(followPan({ px: -5000, py: 400, ...box, s: 2, x: 200, y: 0 })).toBeNull();
  });
});
