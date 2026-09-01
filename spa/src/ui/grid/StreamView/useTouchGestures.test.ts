// The hook's CONSTRUCTION path, end to end onto the wire encoders — because the
// corner-teleport bug (rhapsody, 2026-08-24) lived in the seam between three
// pieces that were each correct on their own: input/trackpad omits a rel
// station's button coordinates, useStreamControl passes the omission through,
// and streamClient/inputWire then substituted a position that had never been
// known. Nothing below the hook can be trusted from a unit test of one layer, so
// these drive the real chain and read what would go on the wire.
import { createElement } from 'react';
import { act, create } from 'react-test-renderer';
import { describe, expect, it } from 'vitest';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import { sendButtonImpl, sendMoveAbsImpl, sendMoveRelImpl, type StreamClientLike } from '../../../three/streamClient/inputWire';
import { useTouchGestures, type TouchGestureController } from './useTouchGestures';
import type { GestureState, Vec2 } from './types';

// The hook schedules its deferred tap-release on `window` (the deadline that
// makes tap-then-hold a drag). These tests never let it fire — they assert on
// what the DOWN edge already put on the wire — so a timer host is all it needs.
(globalThis as unknown as { window: unknown }).window ??= {
  setTimeout: (fn: () => void, ms: number) => setTimeout(fn, ms),
  clearTimeout: (id: number) => clearTimeout(id),
};

/** A client that records the framed records instead of writing them to QUIC. */
function wireRecorder() {
  const records: Uint8Array[] = [];
  const c: StreamClientLike = {
    cseq: 0,
    stationId: null,
    lastAbsX: null,
    lastAbsY: null,
    moveSent: 0,
    moveRejected: 0,
    moveDesiredMin: Infinity,
    dgWriter: null,
    writeDatagram: (b) => { records.push(b); },
    writeReliableClass: (_cls, rec) => { records.push(rec); },
    noteMoveWire: () => { c.moveSent++; },
    nextCseq: () => ++c.cseq,
  };
  /** Every button record's carried point, decoded as streamhost input.rs does. */
  const buttonPoints = () => records
    .filter((r) => r[0] === 2)
    .map((r) => (r.length >= 11
      ? { x: new DataView(r.buffer, r.byteOffset).getUint16(3, true), y: new DataView(r.buffer, r.byteOffset).getUint16(5, true) }
      : null));
  return { c, records, buttonPoints };
}

/** The slice of StreamControlHandle the touch path actually calls, wired to a
 *  real encoder so a test sees the bytes and not just the call. */
function fakeControl(c: StreamClientLike, res: { w: number; h: number }): StreamControlHandle {
  return {
    sendMouseMove: (x: number, y: number) => sendMoveAbsImpl(c, x, y),
    sendMouseMoveRel: (dx: number, dy: number) => sendMoveRelImpl(c, dx, dy),
    sendMouseButton: (b: number, down: boolean, x?: number, y?: number) => sendButtonImpl(c, b, down, x, y),
    getResolution: () => res,
  } as unknown as StreamControlHandle;
}

function mount(opts: { pointerRel: boolean; res: { w: number; h: number } }) {
  const { c, buttonPoints, records } = wireRecorder();
  const controlRef = { current: fakeControl(c, opts.res) };
  const pressedButtonsRef = { current: new Set<number>() };
  const trackpadRef = { current: true };
  const cursorRef: { current: Vec2 | null } = { current: null };
  const heldRef = { current: false };
  const gestureRef = { current: { x: 0, y: 0, s: 1 } as GestureState };
  const stageRef = { current: null as HTMLDivElement | null };
  let controller: TouchGestureController | null = null;
  function Probe({ pointerRel }: { pointerRel: boolean }) {
    const r = useTouchGestures({
      controlRef, pressedButtonsRef, pointerRel, trackpadRef, cursorRef, heldRef,
      gestureRef, stageRef, presentAspect: null,
    });
    controller = r.controller;
    return null;
  }
  let renderer: ReturnType<typeof create>;
  act(() => { renderer = create(createElement(Probe, { pointerRel: opts.pointerRel })); });
  return {
    ctl: () => controller as TouchGestureController,
    buttonPoints, records, cursorRef,
    rerender: (pointerRel: boolean) => act(() => { renderer.update(createElement(Probe, { pointerRel })); }),
  };
}

/** A glide then a still tap — the gesture the operator reproduced with. */
function glideThenTap(ctl: TouchGestureController) {
  ctl.begin(1, 0, 0, 0, 100, 100);
  for (let i = 1; i <= 97; i++) ctl.move(1, 0, 0, i, 100 + i, 100);
  ctl.end(1, 0, 0, 120, 197, 100);
  ctl.begin(2, 0, 0, 500, 200, 200);   // a second, still contact…
  ctl.end(2, 0, 0, 560, 200, 200);     // …released in place → a tap
}

describe('useTouchGestures — a rel station never puts an absolute point on the wire', () => {
  it('REGRESSION: the first tap after a fresh mount carries no coordinates', () => {
    const h = mount({ pointerRel: true, res: { w: 1152, h: 900 } });
    glideThenTap(h.ctl());
    const pts = h.buttonPoints();
    expect(pts.length).toBeGreaterThan(0);
    // Before the fix every one of these was { x: 0, y: 0 }, and the daemon's
    // abs→rel bridge pinned the guest cursor to the top-left corner.
    expect(pts.every((p) => p === null)).toBe(true);
    expect(h.cursorRef.current).toBeNull(); // no local sprite on a rel station
  });

  it('the glide really did ship relative motion (the tap is not the first sample)', () => {
    const h = mount({ pointerRel: true, res: { w: 1152, h: 900 } });
    glideThenTap(h.ctl());
    expect(h.records.filter((r) => r[0] === 4).length).toBeGreaterThan(0);
    expect(h.records.some((r) => r[0] === 1)).toBe(false); // never an abs move
  });

  it('a station whose rel flag ARRIVES LATE still drives a rel engine', () => {
    // The engine used to be memoized on the first render's value, which would
    // make a late-arriving `true` permanently invisible to it.
    const h = mount({ pointerRel: false, res: { w: 1152, h: 900 } });
    h.rerender(true);
    glideThenTap(h.ctl());
    expect(h.buttonPoints().every((p) => p === null)).toBe(true);
  });

  it('an ABS station still clicks at its virtual cursor', () => {
    const h = mount({ pointerRel: false, res: { w: 640, h: 480 } });
    const ctl = h.ctl();
    ctl.begin(1, 0, 0, 0, 100, 100);
    ctl.end(1, 0, 0, 60, 100, 100);
    expect(h.buttonPoints()[0]).toEqual({ x: 320, y: 240 }); // the centred seed
  });

  it('an ABS station with no resolution yet clicks WHERE THE GUEST IS, not at a corner', () => {
    // getResolution() is {0,0} until the first frame. Centring that gave (1,1) —
    // a fabricated corner. A coordinate-free edge lets the guest keep its cursor.
    const h = mount({ pointerRel: false, res: { w: 0, h: 0 } });
    const ctl = h.ctl();
    ctl.begin(1, 0, 0, 0, 100, 100);
    ctl.end(1, 0, 0, 60, 100, 100);
    expect(h.buttonPoints()[0]).toBeNull();
    expect(h.cursorRef.current).toBeNull();
  });
});
