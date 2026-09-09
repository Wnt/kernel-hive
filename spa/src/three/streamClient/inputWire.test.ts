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
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configureTracer, __resetTracer, __bufferedSpans } from '../../analytics/trace';
import { SUFFIX_LEN, __resetSampleCounter } from './inputTrace';
import { setTransportFacts, clearTransportFacts } from './transportFacts';
import { ICLASS_BUTTON, T_BUTTON, T_MOVE_REL } from './constants';
import {
  sendButtonImpl, sendKeyScancodeImpl, sendMoveAbsImpl, sendMoveRelImpl, type StreamClientLike,
} from './inputWire';

function fakeClient() {
  const reliable: { cls: number; rec: Uint8Array }[] = [];
  const datagrams: Uint8Array[] = [];
  const c: StreamClientLike = {
    cseq: 0,
    stationId: null,
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
/** The daemon's own read of a button record, suffix and all.
 *
 *  STRIPS THE TRACE SUFFIX FIRST, exactly as `streamhost/src/input_trace.rs`
 *  does: a base length plus 25 with the marker byte where the suffix would
 *  start IS a suffix, and the record proper is what remains. Since every key
 *  and click edge is traced (2026-09-01) that is now the COMMON case rather
 *  than a 1-in-10 one, and a decoder that skipped the strip would read a
 *  3-byte coordinate-free edge as an 11-byte one carrying a position — which
 *  is precisely the corner-pinning fault the regression below exists for. */
function stripSuffix(rec: Uint8Array): Uint8Array {
  for (const base of [3, 11]) {
    if (rec.length === base + SUFFIX_LEN && rec[base] === 0xc5) return rec.subarray(0, base);
  }
  return rec;
}

function decodeButton(raw: Uint8Array) {
  const rec = stripSuffix(raw);
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

// ---------------------------------------------------------------------------
// The transport hop as its own span. A sampled edge's record does not vanish
// into an unexplained gap between the browser and the daemon: the handoff to
// the QUIC stream writer is a span of its own, carrying the connection's
// identity and characteristics (transportFacts.ts). An UNSAMPLED edge emits
// nothing at all — the 9-in-10 case still costs one counter check.
// ---------------------------------------------------------------------------
describe('input.wire', () => {
  beforeEach(() => {
    __resetTracer();
    configureTracer({ enabled: true, emit: () => {} });
    __resetSampleCounter();
    setTransportFacts('https://labhost:8443/wt', {});
  });
  afterEach(() => { clearTransportFacts(); });

  function sampledKey() {
    const { c, reliable } = fakeClient();
    sendKeyScancodeImpl(c, 0x1e, true);
    return { reliable };
  }

  it('wraps the sampled write in a client-kind child of input.edge', () => {
    vi.useFakeTimers();
    try {
      sampledKey();
      const wire = __bufferedSpans().filter((s) => s.n === 'input.wire');
      expect(wire).toHaveLength(1);
      expect(wire[0].kd).toBe('client');
      // `input.edge` is NOT buffered yet, and that is the contract: it stays
      // OPEN until the frame that answers it paints, because its duration is
      // the visitor's round trip (inputTrace.ts::settleEdge). Its child ending
      // first is normal.
      expect(__bufferedSpans().map((s) => s.n)).not.toContain('input.edge');
      // Nothing answers it here, so the unanswered timeout settles it — and
      // only then can the parent link be compared.
      vi.advanceTimersByTime(5000);
      const edge = __bufferedSpans().filter((s) => s.n === 'input.edge');
      expect(edge).toHaveLength(1);
      expect(wire[0].p).toBe(edge[0].s);
    } finally {
      vi.useRealTimers();
    }
  });

  it('carries the endpoint, protocol and reliability class of the real hop', () => {
    sampledKey();
    const a = __bufferedSpans().find((s) => s.n === 'input.wire')!.a!;
    expect(a['server.address']).toBe('labhost');
    expect(a['server.port']).toBe(8443);
    expect(a['net.peer.port']).toBe(8443);
    expect(a['network.transport']).toBe('quic');
    expect(a['network.protocol.version']).toBe('3');
    expect(a['kh.wire.reliability']).toBe('stream');
    expect(a['peer.service']).toBe('kernel-hive-daemon');
  });

  it('still puts the record on the wire, suffix and all', () => {
    const { reliable } = sampledKey();
    expect(reliable).toHaveLength(1);
    // 4 base bytes + the 25-byte trace suffix, on EVERY key edge now.
    expect(reliable[0].rec.length).toBe(4 + SUFFIX_LEN);
  });

  it('emits nothing at all when tracing is switched off', () => {
    configureTracer({ enabled: false, emit: () => {} });
    const { c, reliable } = fakeClient();
    sendKeyScancodeImpl(c, 0x1e, true);
    expect(__bufferedSpans()).toHaveLength(0);
    // A NOOP span has no ids, so no suffix goes on the wire either — the
    // daemon must never be handed an all-zero context (`input_trace::strip`
    // rejects one, but not sending it is the honest half).
    expect(reliable[0].rec.length).toBe(4);
  });
});
