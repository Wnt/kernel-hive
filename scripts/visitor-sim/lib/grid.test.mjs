// grid.test.mjs — the window-tiling geometry, verified without a browser.
// Run: node --test scripts/visitor-sim/lib/grid.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { autoGrid, parseGridSpec, parseScreenSpec, cellBounds, GridSlots } from './grid.mjs';

test('autoGrid packs six windows into 3x2', () => {
  assert.deepEqual(autoGrid(6), { cols: 3, rows: 2 });
});

test('autoGrid stays square-ish across sizes', () => {
  assert.deepEqual(autoGrid(1), { cols: 1, rows: 1 });
  assert.deepEqual(autoGrid(4), { cols: 2, rows: 2 });
  assert.deepEqual(autoGrid(9), { cols: 3, rows: 3 });
  assert.deepEqual(autoGrid(12), { cols: 4, rows: 3 });
});

test('parseGridSpec accepts CxR and rejects junk', () => {
  assert.deepEqual(parseGridSpec('3x2'), { cols: 3, rows: 2 });
  assert.throws(() => parseGridSpec('3'), /COLSxROWS/);
  assert.throws(() => parseGridSpec('0x2'), />= 1/);
  assert.throws(() => parseGridSpec('axb'), /COLSxROWS/);
});

test('parseScreenSpec accepts WxH and rejects the implausible', () => {
  assert.deepEqual(parseScreenSpec('1440x900'), { w: 1440, h: 900 });
  assert.throws(() => parseScreenSpec('1440'), /WxH/);
  assert.throws(() => parseScreenSpec('10x10'), /implausibly small/);
});

test('cellBounds tiles a 1440x900 screen into a 3x2 grid with no overlap', () => {
  const opts = { grid: { cols: 3, rows: 2 }, screen: { w: 1440, h: 900 }, gap: 8, top: 28 };
  const cells = [0, 1, 2, 3, 4, 5].map((s) => cellBounds(s, opts));
  // every cell fits inside the screen
  for (const c of cells) {
    assert.ok(c.left >= 0 && c.top >= 28, `cell starts on-screen: ${JSON.stringify(c)}`);
    assert.ok(c.left + c.width <= 1440, `cell right edge on-screen: ${JSON.stringify(c)}`);
    assert.ok(c.top + c.height <= 900, `cell bottom edge on-screen: ${JSON.stringify(c)}`);
  }
  // the three windows in the top row share a top and step right by the same dx
  assert.equal(cells[0].top, cells[1].top);
  assert.equal(cells[1].top, cells[2].top);
  assert.equal(cells[1].left - cells[0].left, cells[2].left - cells[1].left);
  // the second row sits strictly below the first
  assert.ok(cells[3].top > cells[0].top + cells[0].height);
  // no two windows overlap horizontally within a row (gap between them)
  assert.ok(cells[1].left >= cells[0].left + cells[0].width);
});

test('cellBounds wraps past capacity instead of walking off-screen', () => {
  const opts = { grid: { cols: 3, rows: 2 }, screen: { w: 1440, h: 900 } };
  // slot 6 (one past the 6-cell grid) lands back on cell 0
  assert.deepEqual(cellBounds(6, opts), cellBounds(0, opts));
});

test('GridSlots hands out lowest-free-first and reuses a released cell', () => {
  const slots = new GridSlots(6);
  const a = slots.take(); // 0
  const b = slots.take(); // 1
  const c = slots.take(); // 2
  assert.deepEqual([a, b, c], [0, 1, 2]);
  slots.release(b); // free 1
  assert.equal(slots.take(), 1, 'the freed cell is reused before a new one');
  assert.equal(slots.take(), 3, 'then the next unused cell');
});

test('GridSlots overflows past capacity without blocking', () => {
  const slots = new GridSlots(2);
  assert.deepEqual([slots.take(), slots.take()], [0, 1]);
  assert.equal(slots.take(), 2, 'a third visitor still gets a (wrapping) slot');
  assert.equal(slots.take(), 3);
});
