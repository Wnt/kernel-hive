// grid.mjs — lay the headed visitor windows out as a tiled grid instead of a
// stack. Pure geometry and a slot allocator; the actual window move lives in
// visitor-sim.mjs (one CDP `Browser.setWindowBounds` per page), because that
// is the only part that needs a live browser. Keeping the math here makes it
// testable without one — see grid.test.mjs.
//
// COORDINATES ARE POINTS, NOT PIXELS. Chrome's window bounds (and macOS window
// positions generally) are in logical points, so on a 2880x1800 Retina panel
// the usable area is 1440x900, not 2880x1800. `--screen` is therefore given in
// points; the default matches a 15" MacBook Pro's default "Looks like" mode.

/** The smallest roughly-square grid that holds `n` windows: 6 -> 3x2, 9 -> 3x3,
 *  4 -> 2x2. Columns first, so a partly-filled last row sits at the bottom. */
export function autoGrid(n) {
  const cols = Math.max(1, Math.ceil(Math.sqrt(n)));
  const rows = Math.max(1, Math.ceil(n / cols));
  return { cols, rows };
}

/** Parse a `--grid CxR` spec (e.g. "3x2") into {cols, rows}, or throw. */
export function parseGridSpec(spec) {
  const m = /^(\d+)x(\d+)$/.exec(String(spec).trim());
  if (!m) throw new Error(`--grid must look like COLSxROWS (e.g. 3x2), got "${spec}"`);
  const cols = Number(m[1]);
  const rows = Number(m[2]);
  if (cols < 1 || rows < 1) throw new Error(`--grid COLSxROWS must both be >= 1, got "${spec}"`);
  return { cols, rows };
}

/** Parse a `--screen WxH` spec (points) into {w, h}, or throw. */
export function parseScreenSpec(spec) {
  const m = /^(\d+)x(\d+)$/.exec(String(spec).trim());
  if (!m) throw new Error(`--screen must look like WxH in points (e.g. 1440x900), got "${spec}"`);
  const w = Number(m[1]);
  const h = Number(m[2]);
  if (w < 200 || h < 200) throw new Error(`--screen WxH is implausibly small: "${spec}"`);
  return { w, h };
}

/** The bounds (points) of one cell in the grid. `slot` is 0-based, filled
 *  left-to-right, top-to-bottom, wrapping if it exceeds cols*rows so an
 *  oversized concurrency degrades to overlapping windows rather than throwing.
 *  `top` reserves the macOS menu bar; `gap` is the space between and around
 *  windows. */
export function cellBounds(slot, { grid, screen, gap = 8, top = 28 }) {
  const { cols, rows } = grid;
  const cell = slot % (cols * rows);
  const col = cell % cols;
  const row = Math.floor(cell / cols);
  const width = Math.floor((screen.w - gap * (cols + 1)) / cols);
  const height = Math.floor((screen.h - top - gap * (rows + 1)) / rows);
  const left = gap + col * (width + gap);
  const topPx = top + gap + row * (height + gap);
  return { left, top: topPx, width, height };
}

/** A fixed set of grid slots, handed out lowest-free-first and returned when a
 *  window closes, so a later visitor reuses a freed cell rather than opening a
 *  brand-new one off the edge. Capacity is cols*rows; take() past capacity
 *  returns a wrapping index (see cellBounds) so it never blocks a visitor. */
export class GridSlots {
  constructor(capacity) {
    this.capacity = capacity;
    this.used = new Set();
    this.overflow = capacity; // next index once every real cell is taken
  }

  take() {
    for (let i = 0; i < this.capacity; i++) {
      if (!this.used.has(i)) {
        this.used.add(i);
        return i;
      }
    }
    return this.overflow++; // every cell busy — wrap onto an existing one
  }

  release(slot) {
    this.used.delete(slot);
  }
}
