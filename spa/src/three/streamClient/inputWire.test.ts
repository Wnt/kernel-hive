// Wire coverage for the browser→daemon INPUT record encoders — specifically the
// one thing a button record cannot say in 11 bytes: "I do not know where the
// pointer is". A button ALWAYS carried a point, substituting the client's cached
// last absolute position when the caller gave none. On a RELATIVE-pointer
// station that cache is never written (all motion ships as type-4 RelMotion), so
// the first coordinate-free button of a session shipped the field's initial
// value — (0,0) — and the daemon's abs→rel bridge dutifully drove the guest
// cursor to the top-left corner. Measured on rhapsody, 2026-08-24:
//   [input] ABS->REL recv=(0,0) off=(0,0) scale=2.09 -> target=(0,0)
// See docs/lab/INPUT-DEBUGGING.md.
import { describe, expect, it } from 'vitest';
import { ICLASS_BUTTON, T_BUTTON, T_MOVE_REL } from './constants';
import { sendButtonImpl, sendMoveAbsImpl, sendMoveRelImpl, type StreamClientLike } from './inputWire';

function fakeClient() {
  const reliable: { cls: number; rec: Uint8Array }[] = [];
  const datagrams: Uint8Array[] = [];
  const c: StreamClientLike = {
    cseq: 0,
    lastAbsX: null,
    lastAbsY: null,
    moveSent: 0,
    moveRejected: 0,
    moveDesiredMin: Infinity,
    dgWriter: null,
    writeDatagram: (b) => { datagrams.push(b); },
    writeReliableClass: (cls, rec) => { reliable.push({ cls, rec }); },
    noteMoveWire: () => { c.moveSent++; },
    nextCseq: () => ++c.cseq,
  };
  return { c, reliable, datagrams };
}

/** Decode a type-2 button record the way streamhost/src/input.rs case 2 does. */
function decodeButton(rec: Uint8Array) {
  expect(rec[0]).toBe(T_BUTTON);
  const carried = rec.length >= 11
    ? {
        x: new DataView(rec.buffer, rec.byteOffset).getUint16(3, true),
        y: new DataView(rec.buffer, rec.byteOffset).getUint16(5, true),
      }
    : null; // the daemon applies NO position to a record this short
  return { button: rec[1], down: rec[2] !== 0, carried };
}

describe('inputWire — a button record only carries a point it actually knows', () => {
  it('REGRESSION: a rel station\'s first click never ships an abs (0,0)', () => {
    const { c, reliable } = fakeClient();
    // A real trackpad glide on a rel station: ~100 RelMotion samples, no abs move.
    for (let i = 0; i < 97; i++) sendMoveRelImpl(c, 3, -2);
    // …then a tap. input/trackpad's buttonEdge omits the coords on purpose.
    sendButtonImpl(c, 0, true);
    sendButtonImpl(c, 0, false);
    expect(reliable.map((r) => r.cls)).toEqual([ICLASS_BUTTON, ICLASS_BUTTON]);
    for (const { rec } of reliable) {
      // Before the fix this was { x: 0, y: 0 } — the daemon read it as a real
      // absolute target and pinned the guest cursor to the corner.
      expect(decodeButton(rec).carried).toBeNull();
    }
  });

  it('a coordinate-free button still carries the last KNOWN point on an abs station', () => {
    const { c, reliable } = fakeClient();
    sendMoveAbsImpl(c, 640, 480);
    sendButtonImpl(c, 0, true);          // the tap's press, where the cursor is
    sendButtonImpl(c, 0, false);         // …and its release, no fresh point
    for (const { rec } of reliable) {
      expect(decodeButton(rec).carried).toEqual({ x: 640, y: 480 });
    }
  });

  it('an explicit point always rides, including a legitimate (0,0) corner click', () => {
    const { c, reliable } = fakeClient();
    sendButtonImpl(c, 0, true, 0, 0);
    expect(decodeButton(reliable[0].rec).carried).toEqual({ x: 0, y: 0 });
    // …and it becomes the known position for the release that follows.
    sendButtonImpl(c, 0, false);
    expect(decodeButton(reliable[1].rec).carried).toEqual({ x: 0, y: 0 });
  });

  it('a rel move never makes a position known', () => {
    const { c, datagrams } = fakeClient();
    sendMoveRelImpl(c, 10, 10);
    expect(datagrams[0][0]).toBe(T_MOVE_REL);
    expect(c.lastAbsX).toBeNull();
    expect(c.lastAbsY).toBeNull();
  });
});
