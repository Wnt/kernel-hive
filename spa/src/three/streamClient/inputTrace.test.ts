// inputTrace.ts's contract: the browser samples 1-in-N (never the daemon),
// the wire suffix round-trips through the exact 25-byte layout
// streamhost/src/input_trace.rs decodes, and the key-class buckets it hands
// out match that module's vocabulary word for word.
import { describe, expect, it, beforeEach } from 'vitest';
import { configureTracer, __resetTracer } from '../../analytics/trace';
import {
  SAMPLE_N, SUFFIX_LEN, maybeSampleEdge, traceSuffix, withSuffix, keyClass,
  __resetSampleCounter, BACKEND_TRACE_ID_RE,
} from './inputTrace';

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
  it('samples exactly 1 edge in SAMPLE_N, never zero and never two in a row', () => {
    const sampled: number[] = [];
    for (let i = 1; i <= SAMPLE_N * 5; i += 1) {
      const span = maybeSampleEdge('input.edge', { 'kh.input.class': 'key' });
      if (span) sampled.push(i);
    }
    expect(sampled).toEqual([SAMPLE_N, SAMPLE_N * 2, SAMPLE_N * 3, SAMPLE_N * 4, SAMPLE_N * 5]);
  });

  it('an unsampled edge costs no id mint: traceId is only ever real on a hit', () => {
    let hits = 0;
    for (let i = 0; i < SAMPLE_N * 3; i += 1) {
      const span = maybeSampleEdge('input.edge', {});
      if (span) {
        hits += 1;
        expect(span.traceId).toMatch(/^[0-9a-f]{32}$/);
        span.end('ok');
      }
    }
    expect(hits).toBe(3);
  });
});

describe('the EUM↔backend join (Instana reportEvent)', () => {
  it('reports backendTraceId as EXACTLY 32 hex chars — the vendor silently drops anything else', () => {
    const { calls } = installIneum();
    for (let i = 0; i < SAMPLE_N - 1; i += 1) maybeSampleEdge('input.edge', {});
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
    for (let i = 0; i < SAMPLE_N - 1; i += 1) maybeSampleEdge('input.edge', {});
    // Must not throw, and must still return a real sampled span.
    const span = maybeSampleEdge('input.edge', {});
    expect(span).not.toBeNull();
    expect(span!.traceId).toMatch(/^[0-9a-f]{32}$/);
  });

  it('sends nothing on an unsampled edge, and nothing when tracing is disabled', () => {
    const { calls } = installIneum();
    // Unsampled edges: no span, so no reportEvent either.
    for (let i = 0; i < SAMPLE_N - 1; i += 1) maybeSampleEdge('input.edge', {});
    expect(calls.filter(([name]) => name === 'reportEvent')).toHaveLength(0);

    // Tracing disabled entirely: even a "sampled" edge mints a NOOP span
    // (empty traceId), which must never be reported.
    configureTracer({ enabled: false, emit: () => {} });
    const span = maybeSampleEdge('input.edge', {});
    expect(span!.traceId).toBe('');
    expect(calls.filter(([name]) => name === 'reportEvent')).toHaveLength(0);
  });
});

describe('wire suffix', () => {
  it('is exactly 25 bytes: 1 marker + 16 trace-id + 8 span-id', () => {
    expect(SUFFIX_LEN).toBe(25);
  });

  it('round-trips a span\'s ids as big-endian bytes matching the hex string order', () => {
    // Force a sample.
    for (let i = 0; i < SAMPLE_N - 1; i += 1) maybeSampleEdge('input.edge', {});
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
