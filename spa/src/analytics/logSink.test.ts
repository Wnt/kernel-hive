// Tests for the browser's log lane. The theme is the one property the flat
// clientlog.jsonl could never have: a record must carry the trace context that
// was open WHEN IT HAPPENED, not whatever is open when the batch leaves.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  __pendingLogs, __resetLogSink, configureLogSink, flushLogs, logRecord,
  type Severity,
} from './logSink';
import { __resetTracer, configureTracer, popActive, pushActive, startTrace } from './trace';

beforeEach(() => {
  __resetLogSink();
  __resetTracer();
  configureTracer({ enabled: true, emit: () => {} });
  configureLogSink({ allowed: true, sessionId: 'sess1' });
});

afterEach(() => {
  vi.unstubAllGlobals();
  __resetLogSink();
});

describe('consent', () => {
  it('queues nothing until the lane is allowed', () => {
    configureLogSink({ allowed: false, sessionId: 'sess1' });
    logRecord('stall', 'video froze', 'win95');
    expect(__pendingLogs()).toHaveLength(0);
  });
});

describe('severity', () => {
  it('maps the events an operator filters on, and defaults the rest to INFO', () => {
    const cases: [string, Severity][] = [
      ['client-error', 'ERROR'],
      ['connect-giveup', 'ERROR'],
      ['stall', 'WARN'],
      ['stats', 'DEBUG'],
      ['station-open', 'INFO'],
    ];
    for (const [event] of cases) logRecord(event, 'x', 'win95');
    expect(__pendingLogs().map((r) => r.sv)).toEqual(cases.map(([, sv]) => sv));
  });
});

describe('trace correlation', () => {
  it('stamps the span that was open when the event happened', () => {
    const span = startTrace('station.open');
    pushActive(span);
    logRecord('stall', 'video froze', 'win95');
    popActive(span);
    const [rec] = __pendingLogs();
    expect(rec.tr).toBe(span.traceId);
    expect(rec.sp).toBe(span.spanId);
  });

  it('does NOT borrow a later span for an earlier record — the whole point', () => {
    logRecord('stall', 'before any span', 'win95');
    const later = startTrace('station.open');
    pushActive(later);
    logRecord('stall', 'inside the span', 'win95');
    popActive(later);
    const [first, second] = __pendingLogs();
    expect(first.tr).toBeUndefined();
    expect(second.tr).toBe(later.traceId);
  });

  it('records with no span in scope are still queued, honestly uncorrelated', () => {
    logRecord('client-error', 'boom', '');
    expect(__pendingLogs()).toHaveLength(1);
    expect(__pendingLogs()[0].tr).toBeUndefined();
  });
});

describe('attributes', () => {
  it('carries the event, the station and anything the caller adds — a stack included', () => {
    logRecord('client-error', 'boom', 'win95', { 'exception.stacktrace': 'at foo (x.js:1:1)' });
    expect(__pendingLogs()[0].a).toMatchObject({
      'kh.event': 'client-error',
      'kh.station': 'win95',
      'exception.stacktrace': 'at foo (x.js:1:1)',
    });
  });
});

describe('flush', () => {
  it('POSTs one resource envelope and the queued records to /logs', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', fetchMock);
    logRecord('stall', 'video froze', 'win95');
    flushLogs(true);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/logs');
    const body = JSON.parse(String(init.body)) as {
      resource: Record<string, string>;
      logs: { b: string }[];
    };
    expect(body.resource['service.name']).toBe('kernel-hive-spa');
    expect(body.resource['session.id']).toBe('sess1');
    expect(body.logs).toHaveLength(1);
    expect(body.logs[0].b).toBe('video froze');
    expect(__pendingLogs()).toHaveLength(0);
    await Promise.resolve();
  });

  it('a network failure folds the batch back; the evidence is not dropped', async () => {
    const fetchMock = vi.fn().mockRejectedValue(new Error('offline'));
    vi.stubGlobal('fetch', fetchMock);
    logRecord('stall', 'video froze', 'win95');
    flushLogs(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(__pendingLogs()).toHaveLength(1);
  });

  it('an HTTP refusal is a settled answer: the batch is dropped, not requeued forever', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: false });
    vi.stubGlobal('fetch', fetchMock);
    logRecord('stall', 'video froze', 'win95');
    flushLogs(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(__pendingLogs()).toHaveLength(0);
  });
});
