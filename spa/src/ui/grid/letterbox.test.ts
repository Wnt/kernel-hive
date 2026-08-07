// Unit coverage for the 2D letterbox coordinate map (StreamView's inverse of
// object-fit:contain). No existing framework-free test covered this module.
import { describe, expect, it } from 'vitest';
import { clientToGuest, contentRectFor, type ContentRect } from './letterbox';

describe('contentRectFor', () => {
  it('letterboxes top/bottom when the source is wider than the box', () => {
    const rect: ContentRect = contentRectFor(800, 800, { w: 1024, h: 768 });
    expect(rect.width).toBe(800);
    expect(rect.height).toBeCloseTo(600, 5);
    expect(rect.offsetX).toBe(0);
    expect(rect.offsetY).toBeCloseTo(100, 5);
  });

  it('pillarboxes left/right when the source is taller/narrower than the box', () => {
    const rect = contentRectFor(800, 800, { w: 480, h: 800 });
    expect(rect.height).toBe(800);
    expect(rect.width).toBeCloseTo(480, 5);
    expect(rect.offsetY).toBe(0);
    expect(rect.offsetX).toBeCloseTo(160, 5);
  });

  it('degrades to the raw box when box or source dimensions are non-positive', () => {
    expect(contentRectFor(0, 800, { w: 4, h: 3 })).toEqual({ offsetX: 0, offsetY: 0, width: 0, height: 800 });
    expect(contentRectFor(800, 600, { w: 0, h: 3 })).toEqual({ offsetX: 0, offsetY: 0, width: 800, height: 600 });
  });

  it('fill mode makes the image occupy the whole box (no letterbox bars)', () => {
    // Era-correct 4:3 tiles stretch (object-fit:fill) to fill the display box, so
    // the content rect is the full box regardless of the source aspect.
    const rect = contentRectFor(800, 600, { w: 720, h: 400 }, true);
    expect(rect).toEqual({ offsetX: 0, offsetY: 0, width: 800, height: 600 });
  });
});

describe('clientToGuest', () => {
  const rect = { left: 100, top: 50, width: 800, height: 800 };
  const res = { w: 1024, h: 768 }; // wider than box -> letterboxed top/bottom

  it('maps a point in the image content to absolute guest pixels', () => {
    // Content rect is 800x600 offset (0, 100) inside the element box.
    const p = clientToGuest(100 /* left edge */, 50 + 100 /* top of content */, rect, res);
    expect(p).toEqual({ x: 0, y: 0 });
  });

  it('maps the far corner of the content rect to the last guest pixel', () => {
    const p = clientToGuest(100 + 800, 50 + 100 + 600, rect, res);
    expect(p).toEqual({ x: res.w - 1, y: res.h - 1 });
  });

  it('clamps onto the image by default when the point lands on a letterbox bar', () => {
    const p = clientToGuest(100 + 400, 50 /* above the letterboxed content */, rect, res);
    expect(p).toEqual({ x: Math.round(0.5 * (res.w - 1)), y: 0 });
  });

  it('returns null off-image when clampToImage is false', () => {
    const p = clientToGuest(100 + 400, 50, rect, res, false);
    expect(p).toBeNull();
  });

  it('returns null when the element box has collapsed to zero area (not yet laid out)', () => {
    expect(clientToGuest(100, 100, { ...rect, width: 0 }, res)).toBeNull();
    expect(clientToGuest(100, 100, { ...rect, height: 0 }, res)).toBeNull();
  });

  it('fill mode spreads the whole box across guest pixels (stretch-independent)', () => {
    // The element box IS the display rect (object-fit:fill), so u/v span the whole
    // box back to real guest pixels — no letterbox bars, mapping stays exact.
    expect(clientToGuest(rect.left, rect.top, rect, res, true, true)).toEqual({ x: 0, y: 0 });
    expect(clientToGuest(rect.left + rect.width, rect.top + rect.height, rect, res, true, true))
      .toEqual({ x: res.w - 1, y: res.h - 1 });
    // Box centre → guest centre, both axes.
    expect(clientToGuest(rect.left + rect.width / 2, rect.top + rect.height / 2, rect, res, true, true))
      .toEqual({ x: Math.round(0.5 * (res.w - 1)), y: Math.round(0.5 * (res.h - 1)) });
  });
});
