// frameTrace.ts's contract: a sampled input's answer is matched by frame_id
// alone, in EITHER arrival order — the mark before the frame finishes
// painting, and the frame finishing before the mark arrives. Never by
// assuming "the next frame painted is the answer" (docs/lab/TRACE-CONTEXT.md
// §3.2/§8.1's explicit rejection of ordering as the mechanism).
import { describe, expect, it, beforeEach, vi } from 'vitest';
import { configureTracer, __resetTracer, __bufferedSpans } from '../../analytics/trace';
import {
  bytesToHex, noteDecodeSubmit, noteDecoded, noteFrameMark, noteReceived,
  __resetFrameTrace,
} from './frameTrace';
import { maybeSampleEdge, __resetSampleCounter } from './inputTrace';

beforeEach(() => {
  __resetTracer();
  configureTracer({ enabled: true, emit: () => {} });
  __resetFrameTrace();
});

const TRACE_ID = 'a'.repeat(32);
const SPAN_ID = 'b'.repeat(16);

function playFrame(frameId: number, ts: number, t0: number): void {
  noteReceived(frameId, t0);
  noteDecodeSubmit(frameId, ts, t0 + 1);
  noteDecoded(ts, t0 + 3, t0 + 3.5);
}

describe('bytesToHex', () => {
  it('renders big-endian bytes as the same lowercase hex traceparent uses', () => {
    const bytes = new Uint8Array([0xa1, 0x02, 0xff, 0x00]);
    expect(bytesToHex(bytes)).toBe('a102ff00');
  });
});

describe('frame/mark matching', () => {
  it('emits the three return-path spans when the mark arrives AFTER paint', () => {
    playFrame(42, 1000, 100);
    expect(__bufferedSpans()).toHaveLength(0); // no mark yet — nothing emitted
    noteFrameMark(42, TRACE_ID, SPAN_ID, 'win95');
    const spans = __bufferedSpans();
    expect(spans.map((s) => s.n)).toEqual([
      'client.frame.receive', 'client.frame.decode', 'client.frame.paint',
    ]);
    for (const s of spans) {
      expect(s.t).toBe(TRACE_ID);
      expect(s.p).toBe(SPAN_ID);
      expect(s.d).toBeGreaterThanOrEqual(0);
      // Same key `analytics/stationAttrs.ts` uses (station-type grouping).
      expect(s.a?.['kh.station.id']).toBe('win95');
    }
  });

  it('emits the same three spans when the mark arrives BEFORE paint finishes', () => {
    noteFrameMark(7, TRACE_ID, SPAN_ID, null);
    expect(__bufferedSpans()).toHaveLength(0); // frame not painted yet
    playFrame(7, 2000, 500);
    const spans = __bufferedSpans();
    expect(spans.map((s) => s.n)).toEqual([
      'client.frame.receive', 'client.frame.decode', 'client.frame.paint',
    ]);
  });

  it('never emits for a frame_id that is never marked', () => {
    playFrame(1, 10, 0);
    playFrame(2, 20, 10);
    playFrame(3, 30, 20);
    expect(__bufferedSpans()).toHaveLength(0);
  });

  it('never emits twice for the same frame_id (consumed on match)', () => {
    playFrame(9, 90, 0);
    noteFrameMark(9, TRACE_ID, SPAN_ID, null);
    noteFrameMark(9, TRACE_ID, SPAN_ID, null); // a duplicate/stray second mark
    expect(__bufferedSpans()).toHaveLength(3);
  });

  it('a mark for an unrelated ts never cross-matches (join key is frame_id, not ts)', () => {
    playFrame(11, 111, 0);
    noteFrameMark(999, TRACE_ID, SPAN_ID, null); // no frame 999 was ever received
    expect(__bufferedSpans()).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// THE ROOT'S OWN DURATION. `input.edge` is left OPEN when an edge is sampled
// and closed HERE, at the paint, so the root of an input trace measures the
// visitor-facing edge -> painted-pixel round trip. Both ends are
// `performance.now()` readings from THIS tab, which is why the number needs no
// clock agreement between the two machines.
//
// It replaced a SIBLING span, `client.input.roundtrip`, which carried this
// figure beside a root whose own duration was 0-1 ms of local enqueue — so
// every consumer that reads a root's duration (a trace list, a latency
// percentile, Instana's endpoint view) read 1 ms for a quarter-second wait.
// ---------------------------------------------------------------------------
describe("input.edge's duration is the round trip", () => {
  it('closes the root AT the paint of the frame that answered it', () => {
    __resetSampleCounter();
    const edge = maybeSampleEdge('input.edge', { 'kh.input.class': 'key' });
    expect(edge).not.toBeNull();
    const traceId = edge!.traceId;
    // NOT ended by the caller: `inputWire.ts` deliberately does not end it.
    expect(__bufferedSpans().filter((s) => s.n === 'input.edge')).toHaveLength(0);

    playFrame(7, 2000, 100);
    noteFrameMark(7, traceId, SPAN_ID, 'win95');

    const roots = __bufferedSpans().filter((s) => s.n === 'input.edge');
    expect(roots).toHaveLength(1);
    expect(roots[0].kd).toBe('client');       // this tab's view of a remote exchange
    expect(roots[0].t).toBe(traceId);
    expect(roots[0].p).toBeNull();            // a ROOT: one trace, one action
    expect(roots[0].a?.['kh.input.answered']).toBe(true);
    expect(roots[0].k).toBe('ok');
    // The sibling span is gone: one measurement, one span.
    expect(__bufferedSpans().map((s) => s.n)).not.toContain('client.input.roundtrip');
  });

  it('a mark for a trace this tab never sampled settles nothing', () => {
    __resetSampleCounter();
    playFrame(8, 3000, 100);
    noteFrameMark(8, TRACE_ID, SPAN_ID, 'win95');
    expect(__bufferedSpans().map((s) => s.n)).not.toContain('input.edge');
  });

  it('settles an edge exactly once, even if two frames are marked against it', () => {
    __resetSampleCounter();
    const edge = maybeSampleEdge('input.edge', {});
    const traceId = edge!.traceId;
    playFrame(9, 4000, 100);
    noteFrameMark(9, traceId, SPAN_ID, 'win95');
    playFrame(10, 5000, 200);
    noteFrameMark(10, traceId, SPAN_ID, 'win95');
    expect(__bufferedSpans().filter((s) => s.n === 'input.edge')).toHaveLength(1);
  });

  it('an edge no frame ever answers still LANDS, saying so', () => {
    // An idle or damage-gated guest may never produce a frame
    // (docs/lab/TRACE-CONTEXT.md §3.4). That edge must not sit open forever:
    // an open span is never buffered, so leaking one deletes the ROOT of its
    // trace — the exact orphan this whole change exists to remove.
    vi.useFakeTimers();
    try {
      __resetSampleCounter();
      maybeSampleEdge('input.edge', {});
      expect(__bufferedSpans().filter((s) => s.n === 'input.edge')).toHaveLength(0);
      vi.advanceTimersByTime(5000);
      const roots = __bufferedSpans().filter((s) => s.n === 'input.edge');
      expect(roots).toHaveLength(1);
      expect(roots[0].a?.['kh.input.answered']).toBe(false);
      expect(roots[0].k).toBe('unset');       // not an error: nothing failed
    } finally {
      vi.useRealTimers();
    }
  });
});
