// inputTrace.ts's contract: the browser samples 1-in-N (never the daemon),
// the wire suffix round-trips through the exact 25-byte layout
// streamhost/src/input_trace.rs decodes, and the key-class buckets it hands
// out match that module's vocabulary word for word.
import { describe, expect, it, beforeEach } from 'vitest';
import { configureTracer, __resetTracer } from '../../analytics/trace';
import {
  SUFFIX_LEN, maybeSampleEdge, traceSuffix, withSuffix, keyClass,
  __resetSampleCounter,
} from './inputTrace';

beforeEach(() => {
  __resetTracer();
  configureTracer({ enabled: true, emit: () => {} });
  __resetSampleCounter();
  delete (globalThis as { window?: unknown }).window;
});

describe('maybeSampleEdge', () => {
  // EVERY key and click edge is traced (2026-09-01). The 1-in-10 counter it
  // replaced aliased against periodic input, applied one rate to populations
  // differing by orders of magnitude, and — the fault no source-side rate can
  // fix — threw away the slow edges, which are the whole point of the
  // measurement.
  it('traces EVERY qualifying edge, with its own trace id', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 30; i += 1) {
      const span = maybeSampleEdge('input.edge', { 'kh.input.class': 'key' });
      expect(span).not.toBeNull();
      expect(span!.traceId).toMatch(/^[0-9a-f]{32}$/);
      seen.add(span!.traceId);
    }
    // One trace per ACTION: thirty edges are thirty traces, never one.
    expect(seen.size).toBe(30);
  });

  it('returns NULL when tracing is switched off, so no zero-id suffix goes out', () => {
    // A NOOP span is TRUTHY with empty ids, and `inputWire.ts` reads
    // `span ? withSuffix(...) : bare` — so returning one appended a 25-byte
    // ALL-ZERO trace context to every record a tracing-disabled tab sent. The
    // daemon rejects a zero context outright (`input_trace::strip`), so those
    // bytes bought nothing at all.
    configureTracer({ enabled: false, emit: () => {} });
    expect(maybeSampleEdge('input.edge', {})).toBeNull();
  });
});

describe('wire suffix', () => {
  it('is exactly 25 bytes: 1 marker + 16 trace-id + 8 span-id', () => {
    expect(SUFFIX_LEN).toBe(25);
  });

  it('round-trips a span\'s ids as big-endian bytes matching the hex string order', () => {
    const span = maybeSampleEdge('input.edge', {});
    expect(span).not.toBeNull();
    const suffix = traceSuffix(span!);
    expect(suffix.length).toBe(SUFFIX_LEN);
    expect(suffix[0]).toBe(0xc5);
    const traceHex = Array.from(suffix.slice(1, 17), (b) => b.toString(16).padStart(2, '0')).join('');
    const spanHex = Array.from(suffix.slice(17, 25), (b) => b.toString(16).padStart(2, '0')).join('');
    expect(traceHex).toBe(span!.traceId);
    expect(spanHex).toBe(span!.spanId);
    span!.end('ok');
  });

  it('withSuffix appends after exactly bodyLen bytes, ignoring any over-allocation', () => {
    const body = new Uint8Array([3, 1, 0x1c, 0x00, 0xff, 0xff]); // 2 spare bytes at the end
    const suffix = new Uint8Array(SUFFIX_LEN).fill(7);
    const out = withSuffix(body, 4, suffix);
    expect(out.length).toBe(4 + SUFFIX_LEN);
    expect(Array.from(out.slice(0, 4))).toEqual([3, 1, 0x1c, 0x00]);
    expect(Array.from(out.slice(4))).toEqual(Array.from(suffix));
  });
});

describe('keyClass — matches input_trace::key_class bucket for bucket', () => {
  it.each([
    [0x001c, 'enter'],
    [0xe01c, 'enter'],
    [0x002a, 'modifier'],
    [0xe05b, 'modifier'],
    [0x0048, 'navigation'],
    [0xe048, 'navigation'],
    [0x000f, 'navigation'],
    [0x003b, 'function'],
    [0x0058, 'function'],
    [0x001e, 'printable'],
    [0x0039, 'printable'],
  ])('scancode 0x%s -> %s', (code, expected) => {
    expect(keyClass(code)).toBe(expected);
  });
});
