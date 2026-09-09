// figure8.test.mjs — the pointer figure-8 geometry, verified without a browser.
// Run: node --test scripts/visitor-sim/lib/figure8.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { figureEightPoints, bootVideoPlayedKey } from './stationOpen.mjs';

// The boot-video skip works only if this key byte-matches App.tsx's
// BOOT_VIDEO_SESSION_PREFIX ('kernelHive.bootVideoPlayed:') + osId. If someone
// renames the SPA constant, this pins the drift so the skip cannot silently rot.
test('bootVideoPlayedKey matches the SPA sessionStorage key', () => {
  assert.equal(bootVideoPlayedKey('win95'), 'kernelHive.bootVideoPlayed:win95');
  assert.equal(bootVideoPlayedKey('nt4'), 'kernelHive.bootVideoPlayed:nt4');
});

const BOX = { cx: 500, cy: 300, ax: 200, ay: 120 };

test('it produces loops*samples + 1 points (closing the curve)', () => {
  const pts = figureEightPoints({ ...BOX, loops: 2, samples: 96 });
  assert.equal(pts.length, 2 * 96 + 1);
});

test('every point stays within the amplitude box', () => {
  const pts = figureEightPoints({ ...BOX, loops: 3, samples: 60 });
  for (const p of pts) {
    assert.ok(Math.abs(p.x - BOX.cx) <= BOX.ax + 1e-9, `x in range: ${p.x}`);
    // |sin t cos t| <= 1/2, so y never exceeds ay/2 from centre
    assert.ok(Math.abs(p.y - BOX.cy) <= BOX.ay / 2 + 1e-9, `y in range: ${p.y}`);
  }
});

test('it is a figure-8: the curve passes back through the vertical centre line', () => {
  // A Gerono lemniscate crosses x=cx (its own middle) twice per loop — that
  // self-crossing is what makes it an 8 rather than an oval. Count sign changes
  // of (x - cx) across one loop.
  const pts = figureEightPoints({ ...BOX, loops: 1, samples: 200 });
  let crossings = 0;
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1].x - BOX.cx;
    const b = pts[i].x - BOX.cx;
    if (a === 0 || (a < 0) !== (b < 0)) crossings++;
  }
  assert.ok(crossings >= 2, `a figure-8 crosses its centre line >= twice, got ${crossings}`);
});

test('it reaches both horizontal extremes (the two lobes)', () => {
  const pts = figureEightPoints({ ...BOX, loops: 1, samples: 200 });
  const xs = pts.map((p) => p.x);
  assert.ok(Math.max(...xs) > BOX.cx + BOX.ax * 0.98, 'reaches the right lobe');
  assert.ok(Math.min(...xs) < BOX.cx - BOX.ax * 0.98, 'reaches the left lobe');
});

test('phase shifts the start without changing the shape', () => {
  const a = figureEightPoints({ ...BOX, loops: 1, samples: 100, phase: 0 });
  const b = figureEightPoints({ ...BOX, loops: 1, samples: 100, phase: Math.PI / 2 });
  // same bounding box, different first point
  assert.notDeepEqual(a[0], b[0]);
  const span = (arr, k) => Math.max(...arr.map((p) => p[k])) - Math.min(...arr.map((p) => p[k]));
  assert.ok(Math.abs(span(a, 'x') - span(b, 'x')) < 1, 'same horizontal span');
});
