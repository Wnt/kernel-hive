// Unit coverage for the PURE pointer-telemetry accumulators (diagnostic drag /
// hover counters). The accumulators own no DOM and no clock, so every case is
// driven with explicit timestamps + wire snapshots.
import { describe, expect, it } from 'vitest';
import {
  HoverAccumulator,
  StrokeAccumulator,
  type WireSnapshot,
} from './pointerTelemetry';

const wire = (sent: number, rejected: number, desiredSizeMin: number | null): WireSnapshot =>
  ({ sent, rejected, desiredSizeMin });

describe('StrokeAccumulator', () => {
  it('emits a compact detail with per-source fire counts, forwarded/coalesced totals and wire deltas', () => {
    const s = new StrokeAccumulator();
    s.begin('pen', { x: 100, y: 200, t: 1000 }, wire(10, 0, 4));
    // A normal, non-pinched drag rides pointerrawupdate (pointermove suppressed).
    s.sample('pointerrawupdate', 3, 3);
    s.sample('pointerrawupdate', 2, 2);
    s.sample('pointermove', 4, 0); // a stray pointermove that forwarded nothing
    const detail = s.finish({ x: 540, y: 190, t: 1812 }, wire(15, 1, -3));
    expect(detail).not.toBeNull();
    expect(JSON.parse(detail as string)).toEqual({
      pt: 'pen',
      durMs: 812,
      raw: 2,
      move: 1,
      fwd: 5,
      coal: 9,
      dg: 5,   // 15 - 10 datagrams enqueued during the stroke
      rej: 1,  // 1 - 0 rejected during the stroke
      dsMin: -3,
      btnHeld: 0,   // no buttons fed
      btnFree: 0,
      btnFlips: 0,
      btn0: -1,
      bbox: null,   // no coords fed → no shape boxes
      rbox: null,
      from: [100, 200],
      to: [540, 190],
      path: [],
    });
  });

  it('captures guest (bbox) + raw (rbox) boxes, a path with per-point buttons, and held/free counts', () => {
    const s = new StrokeAccumulator();
    s.begin('pen', { x: 10, y: 10, t: 0 }, wire(0, 0, 0));
    // A 2-D (circle-like) stroke, button 0 held the whole way (buttons bit 0 = 1).
    s.sample('pointerrawupdate', 1, 1, 10, 10, 100, 100, 1);
    s.sample('pointerrawupdate', 1, 1, 50, 40, 140, 130, 1);
    s.sample('pointerrawupdate', 1, 1, 90, 70, 180, 160, 1);
    const d = JSON.parse(s.finish({ x: 90, y: 70, t: 100 }, wire(3, 0, 0)) as string);
    expect(d.bbox).toEqual([10, 10, 90, 70]);     // guest-px extent (2-D)
    expect(d.rbox).toEqual([100, 100, 180, 160]); // raw client-px extent (2-D)
    expect(d.path).toEqual([[10, 10, 1], [50, 40, 1], [90, 70, 1]]);
    expect(d.btnHeld).toBe(3);
    expect(d.btnFree).toBe(0);
    expect(d.btnFlips).toBe(0);
    expect(d.btn0).toBe(1);
  });

  it('flags a stroke whose button drops mid-way (contact flicker): btnFree>0, btnFlips>0', () => {
    const s = new StrokeAccumulator();
    s.begin('pen', { x: 0, y: 0, t: 0 }, wire(0, 0, 0));
    s.sample('pointerrawupdate', 1, 1, 10, 10, 10, 10, 1); // held
    s.sample('pointerrawupdate', 1, 1, 20, 20, 20, 20, 0); // contact dropped!
    s.sample('pointerrawupdate', 1, 1, 30, 30, 30, 30, 1); // back
    const d = JSON.parse(s.finish({ x: 30, y: 30, t: 30 }, wire(3, 0, 0)) as string);
    expect(d.btnHeld).toBe(2);
    expect(d.btnFree).toBe(1);
    expect(d.btnFlips).toBe(2);            // 1→0 then 0→1
    expect(d.path).toEqual([[10, 10, 1], [20, 20, 0], [30, 30, 1]]);
  });

  it('rounds fractional coords / durations and carries a null desiredSizeMin through', () => {
    const s = new StrokeAccumulator();
    s.begin('mouse', { x: 10.4, y: 20.6, t: 100.2 }, wire(0, 0, null));
    s.sample('pointermove', 1, 1);
    const detail = JSON.parse(s.finish({ x: 30.5, y: 40.5, t: 350.9 }, wire(1, 0, null)) as string);
    expect(detail.durMs).toBe(251);
    expect(detail.from).toEqual([10, 21]);
    expect(detail.to).toEqual([31, 41]);
    expect(detail.dsMin).toBeNull();
  });

  it('no-ops sample() while inactive and finish() returns null without a begin', () => {
    const s = new StrokeAccumulator();
    s.sample('pointerrawupdate', 5, 5); // dropped: no active stroke
    expect(s.finish({ x: 0, y: 0, t: 0 }, wire(0, 0, null))).toBeNull();
  });

  it('resets counters on each begin (an instance is reused across strokes)', () => {
    const s = new StrokeAccumulator();
    s.begin('pen', { x: 0, y: 0, t: 0 }, wire(0, 0, 8));
    s.sample('pointerrawupdate', 9, 9);
    s.finish({ x: 1, y: 1, t: 10 }, wire(9, 0, 8));
    s.begin('pen', { x: 0, y: 0, t: 100 }, wire(9, 0, 8));
    s.sample('pointermove', 2, 1);
    const detail = JSON.parse(s.finish({ x: 2, y: 2, t: 200 }, wire(10, 0, 8)) as string);
    expect(detail).toMatchObject({ raw: 0, move: 1, fwd: 1, coal: 2, dg: 1 });
  });
});

describe('HoverAccumulator', () => {
  it('accumulates seen vs forwarded and emits once the window spans ~1s', () => {
    const h = new HoverAccumulator();
    h.newWindow(0);
    // 5 hover events across the second; the 32ms throttle forwarded only 2.
    h.hover(true);
    h.hover(false);
    h.hover(true);
    h.hover(false);
    expect(h.flush(900)).toBeNull(); // window not yet 1s → keep accumulating
    h.hover(false);
    const detail = h.flush(1000);
    expect(detail).not.toBeNull();
    expect(JSON.parse(detail as string)).toEqual({ hoverSeen: 5, hoverForwarded: 2, windowMs: 1000 });
  });

  it('newWindow is idempotent while open and re-opens after a flush', () => {
    const h = new HoverAccumulator();
    h.newWindow(0);
    h.hover(true);
    h.newWindow(500); // ignored — window already open, t0 stays 0
    h.hover(true);
    const first = JSON.parse(h.flush(1000) as string);
    expect(first).toEqual({ hoverSeen: 2, hoverForwarded: 2, windowMs: 1000 });
    // Window closed by the flush; a fresh newWindow starts a new one.
    h.newWindow(1000);
    h.hover(false);
    expect(h.flush(1500)).toBeNull(); // < 1s of the new window
    expect(JSON.parse(h.flush(2000) as string)).toEqual({ hoverSeen: 1, hoverForwarded: 0, windowMs: 1000 });
  });

  it('hover() and flush() no-op while no window is open', () => {
    const h = new HoverAccumulator();
    h.hover(true); // dropped — no open window
    expect(h.flush(5000)).toBeNull();
  });
});
