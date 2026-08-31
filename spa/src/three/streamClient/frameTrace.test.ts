// frameTrace.ts's contract: a sampled input's answer is matched by frame_id
// alone, in EITHER arrival order — the mark before the frame finishes
// painting, and the frame finishing before the mark arrives. Never by
// assuming "the next frame painted is the answer" (docs/lab/TRACE-CONTEXT.md
// §3.2/§8.1's explicit rejection of ordering as the mechanism).
import { describe, expect, it, beforeEach } from 'vitest';
import { configureTracer, __resetTracer, __bufferedSpans } from '../../analytics/trace';
import {
  bytesToHex, noteDecodeSubmit, noteDecoded, noteFrameMark, noteReceived,
  __resetFrameTrace,
} from './frameTrace';

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
