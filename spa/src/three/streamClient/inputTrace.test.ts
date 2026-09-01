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
// The vendor's own accepted shape now lives beside every other fact about the
// vendor (analytics/instana.ts), and this suite asserts against THAT rule —
// not a looser copy, which would pass while the field is silently dropped.
import { BACKEND_TRACE_ID_RE } from '../../analytics/instana';

beforeEach(() => {
  __resetTracer();
  configureTracer({ enabled: true, emit: () => {} });
  __resetSampleCounter();
  delete (globalThis as { window?: unknown }).window;
});

/** Same pattern `analytics/instana.test.ts` uses: this suite runs under the
 *  `node` vitest environment (no real DOM), so `window` itself has to be
 *  installed on `globalThis`, not merely mutated. */
function installIneum(): { calls: unknown[][] } {
  const calls: unknown[][] = [];
  const fn = (...args: unknown[]) => { calls.push(args); };
  (globalThis as { window?: unknown }).window = { ineum: fn };
  return { calls };
}

describe('maybeSampleEdge', () => {
  // EVERY key and click edge is traced (2026-09-01). The 1-in-10 counter it
  // replaced aliased against periodic input, applied one rate to populations
  // differing by orders of magnitude, and — the fault no source-side rate can
  // fix — threw away the slow edges, which are the whole point of the
  // measurement. The keep/drop decision moved to the vendor export, where the
  // trace is complete and its duration is known.
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

describe('the EUM↔backend join (Instana reportEvent)', () => {
  it('reports backendTraceId as EXACTLY 32 hex chars — the vendor silently drops anything else', () => {
    const { calls } = installIneum();
    const span = maybeSampleEdge('input.edge', { 'kh.input.class': 'key', 'kh.station': 'nextstep' });
    expect(span).not.toBeNull();

    const reportCalls = calls.filter(([name]) => name === 'reportEvent');
    expect(reportCalls.length).toBe(1);
    const [, eventName, opts] = reportCalls[0] as [string, string, {
      backendTraceId: string;
      meta: Record<string, string>;
    }];
    expect(eventName).toBe('kh.input.sampled');
    // The load-bearing assertion: exactly 32 hex, matching the vendor's own
    // accepted shape — a test that only checked "reportEvent was called"
    // would pass even if this were shortened, reformatted, or upper-cased,
    // and the beacon field would then be silently dropped in production.
    expect(opts.backendTraceId).toMatch(/^[0-9a-f]{32}$/);
    expect(opts.backendTraceId).toHaveLength(32);
    expect(BACKEND_TRACE_ID_RE.test(opts.backendTraceId)).toBe(true);
    expect(opts.backendTraceId).toBe(span!.traceId);
    // Meta is forwarded, and never carries a key's identity — only the
    // caller-declared coarse attrs.
    expect(opts.meta['kh.input.class']).toBe('key');
    expect(opts.meta['kh.station']).toBe('nextstep');
  });

  it('is a no-op with no window.ineum: our own tracing is unaffected', () => {
    // Must not throw, and must still return a real traced span.
    const span = maybeSampleEdge('input.edge', {});
    expect(span).not.toBeNull();
    expect(span!.traceId).toMatch(/^[0-9a-f]{32}$/);
  });

  it('sends nothing when tracing is disabled', () => {
    const { calls } = installIneum();
    // Tracing disabled entirely: no span, and nothing reported to the vendor.
    configureTracer({ enabled: false, emit: () => {} });
    expect(maybeSampleEdge('input.edge', {})).toBeNull();
    expect(calls.filter(([name]) => name === 'reportEvent')).toHaveLength(0);
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
