// Tests for the three station/stream flows' telemetry objects.
//
// These guard the rules that were bought with bugs and are invisible in a
// passing build: one episode is one sample, `abandon()` is not a zero, a pair
// of metrics that must stay DISJOINT, and every timing settled on every path
// (the running set is bounded, so a leak silently stops the plane measuring
// anything at all).

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { __resetMetrics } from '../analytics/metrics';
import { __resetFlows } from '../analytics/flows';
import { configureSink, __pendingBatch, __resetSink } from '../analytics/sink';
import { connectTelemetry } from './connectTelemetry';
import { resumeTelemetry } from './resumeTelemetry';
import { recoverTelemetry } from './recoverTelemetry';

/** Same `document` stand-in as analytics/metrics.test.ts — the tests run under
 *  plain Node, so the visibility machinery has nothing to listen to otherwise. */
function installDocument(state: 'visible' | 'hidden') {
  const listeners: Array<() => void> = [];
  const doc = {
    visibilityState: state,
    addEventListener: (_t: string, fn: () => void) => { listeners.push(fn); },
  };
  (globalThis as { document?: unknown }).document = doc;
}

beforeEach(() => {
  __resetMetrics();
  __resetFlows();
  __resetSink();
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
  installDocument('visible');
});

afterEach(() => {
  delete (globalThis as { document?: unknown }).document;
});

const metricIds = () => __pendingBatch().metrics.map((m) => m.id).sort();
const metric = (id: string) => __pendingBatch().metrics.find((m) => m.id === id);
const flowRows = (flow: string) => __pendingBatch().flows.filter((f) => f.flow === flow);

describe('station.open — extending the connect', () => {
  it('counts ATTEMPTS as one sample per attempt-sequence, not one per retry', () => {
    // A recordMetric in the retry path would produce a distribution of ones
    // that says only that retries happen.
    const t = connectTelemetry();
    t.retry();
    t.retry();
    t.firstFrame();
    // 1 (the connect) + 2 retries = 3 attempts; the count ladder has a 3 edge.
    expect(metric('station.open.attemptCount')).toEqual({
      id: 'station.open.attemptCount', bucket: '3', n: 1,
    });
  });

  it('reports a clean connect as 1 attempt, distinguishable from one retry', () => {
    // As RETRIES these would both land in the count ladder's smallest bucket
    // and the commonest case in the whole gallery would be unreadable.
    const a = connectTelemetry();
    a.firstFrame();
    expect(metric('station.open.attemptCount')?.bucket).toBe('1');
    __resetSink();
    configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
    const b = connectTelemetry();
    b.retry();
    b.firstFrame();
    expect(metric('station.open.attemptCount')?.bucket).toBe('2');
  });

  it('does NOT count attempts for a connect that gave up', () => {
    // Committing there would deposit the full ladder length in every failure
    // and turn the metric into a restatement of the failure rate.
    const t = connectTelemetry();
    t.retry();
    t.retry();
    t.gaveUp(false);
    expect(metricIds()).not.toContain('station.open.attemptCount');
  });

  it('times the first input from the FRAME, not from the click that asked for it', () => {
    const t = connectTelemetry();
    t.firstFrame();
    t.firstInput();
    expect(metricIds()).toContain('station.open.toFirstInputMs');
  });

  it('records NO first-input sample when the visitor never touched it', () => {
    // `abandon()` is not a zero: inventing one per un-touched session would
    // report the whole gallery as instantly discoverable.
    const t = connectTelemetry();
    t.firstFrame();
    t.abandoned();
    expect(metricIds()).not.toContain('station.open.toFirstInputMs');
  });

  it('records no first-input sample for input before there was a picture', () => {
    const t = connectTelemetry();
    t.firstInput(); // clicking at a spinner
    t.abandoned();
    expect(metricIds()).not.toContain('station.open.toFirstInputMs');
  });

  it('records nothing at all for a torn-down connect', () => {
    const t = connectTelemetry();
    t.transport();
    t.abandoned();
    expect(__pendingBatch().metrics).toEqual([]);
    // ...and the flow reports no failure either: the abandonment is the
    // funnel's drop-off, not a fault.
    expect(flowRows('station.connect').some((f) => f.outcome === 'fail')).toBe(false);
  });
});

describe('session.resume', () => {
  it('reports nothing for a `focus` hint on a tab that never left', () => {
    // resumeSignals fires up to four times per app switch by design, and a
    // spurious one would otherwise fill the distribution with zero absences.
    const t = resumeTelemetry();
    t.woke();
    t.painted();
    expect(__pendingBatch().metrics).toEqual([]);
    expect(flowRows('session.resume')).toEqual([]);
  });

  it('records the absence, then the return, as one sample each', () => {
    const t = resumeTelemetry();
    t.hidden();
    t.woke();
    t.painted();
    expect(metricIds()).toEqual(['session.resume.awayMs', 'session.resume.toLiveMs']);
    expect(metric('session.resume.toLiveMs')?.n).toBe(1);
  });

  it('keeps the live and reconnect outcomes DISJOINT — one resume, one sample', () => {
    // Fused they would be bimodal and the p95 would only report how often the
    // expensive case happens; both at once would double-count every resume.
    const t = resumeTelemetry();
    t.hidden();
    t.woke();
    t.reconnecting();
    t.painted();
    expect(metricIds()).toContain('session.resume.reconnectToLiveMs');
    expect(metricIds()).not.toContain('session.resume.toLiveMs');
  });

  it('treats a resume that lost the session mid-flight as a RECONNECT', () => {
    const t = resumeTelemetry();
    t.hidden();
    t.woke();
    t.reconnecting();
    t.reconnecting(); // one-way; cannot flip back to the cheaper label
    t.painted();
    expect(metricIds()).not.toContain('session.resume.toLiveMs');
  });

  it('tolerates the four duplicate hints one app switch produces', () => {
    const t = resumeTelemetry();
    t.hidden();
    t.woke();
    t.woke();
    t.woke();
    t.painted();
    expect(metric('session.resume.toLiveMs')?.n).toBe(1);
    expect(metric('session.resume.awayMs')?.n).toBe(1);
  });

  it('records nothing for a visitor who left and never came back', () => {
    const t = resumeTelemetry();
    t.hidden();
    t.end();
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('records no duration for a resume abandoned mid-flight', () => {
    const t = resumeTelemetry();
    t.hidden();
    t.woke();
    t.end();
    // The absence completed and is real; the return never did.
    expect(metricIds()).toEqual(['session.resume.awayMs']);
  });

  it('walks the funnel to firstFrame on a completed resume', () => {
    const t = resumeTelemetry();
    t.hidden();
    t.woke();
    t.painted();
    const rows = flowRows('session.resume');
    expect(rows.some((f) => f.step === 'wake' && f.outcome === 'enter')).toBe(true);
    expect(rows.some((f) => f.step === 'firstFrame' && f.outcome === 'ok')).toBe(true);
  });
});

describe('stream.recover', () => {
  /** A controllable monotonic clock, so the abandonment path — the most
   *  valuable observation in this group — can actually be exercised. */
  function clocked() {
    let t = 0;
    const now = () => t;
    const tel = recoverTelemetry(now);
    tel.heartbeat(2500); // threshold 6000 ms
    return {
      tel,
      /** Paint a MOVING picture for `ms`, so a freeze would be perceptible. */
      move(ms: number) {
        for (let i = 0; i < ms; i += 33) { t += 33; tel.painted(); }
      },
      /** Go silent for `ms`, polling as the real timer would. */
      silent(ms: number) {
        for (let i = 0; i < ms; i += 500) { t += 500; tel.poll(); }
      },
    };
  }

  it('records a recovered freeze as a stall, never as an abandonment', () => {
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.move(200);
    expect(metricIds()).toEqual(['stream.recover.stallMs']);
    expect(metric('stream.recover.stallMs')?.n).toBe(1);
  });

  it('records a visitor leaving mid-freeze as an ABANDONMENT, never as a stall', () => {
    // The only place in the whole system that records somebody giving up.
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.tel.end();
    expect(metricIds()).toEqual(['stream.recover.abandonedAfterMs']);
  });

  it('keeps the pair DISJOINT — one freeze is one sample in exactly one of them', () => {
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.move(200);
    c.tel.end();
    const ids = metricIds();
    expect(ids).toContain('stream.recover.stallMs');
    expect(ids).not.toContain('stream.recover.abandonedAfterMs');
  });

  it('records nothing for a session that never froze', () => {
    // A normal close is not a zero-length stall, and inventing one would drag
    // the whole distribution to the floor.
    const c = clocked();
    c.move(3000);
    c.tel.end();
    expect(__pendingBatch().metrics).toEqual([]);
    expect(flowRows('stream.recover')).toEqual([]);
  });

  it('records nothing for a long gap on an IDLE station', () => {
    // The low-fps trap, end to end: a motionless desktop paints only on its
    // heartbeat, and reporting that as a freeze would make the biggest signal
    // in this metric a property of the exhibit rather than a fault.
    const c = clocked();
    c.tel.painted();
    c.silent(30_000);
    c.tel.end();
    expect(__pendingBatch().metrics).toEqual([]);
  });

  it('opens the funnel at `frozen` and closes it at `moving` on recovery', () => {
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.move(200);
    const rows = flowRows('stream.recover');
    expect(rows.some((f) => f.step === 'frozen' && f.outcome === 'enter')).toBe(true);
    expect(rows.some((f) => f.step === 'moving' && f.outcome === 'ok')).toBe(true);
  });

  it('reports an abandonment as a DROP-OFF, not as a failure', () => {
    // Reporting it as a fault as well would count every abandonment twice:
    // once as a lost visitor, once as a broken stream.
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.tel.end();
    const rows = flowRows('stream.recover');
    expect(rows.some((f) => f.step === 'frozen' && f.outcome === 'enter')).toBe(true);
    expect(rows.some((f) => f.outcome === 'fail')).toBe(false);
    expect(rows.some((f) => f.outcome === 'ok')).toBe(false);
  });

  it('records the client reacting to a freeze as a distinct funnel step', () => {
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.tel.reconnecting();
    c.move(200);
    expect(flowRows('stream.recover').some((f) => f.step === 'reconnecting')).toBe(true);
  });

  it('measures nothing about the stream itself', () => {
    // The boundary from docs/ANALYTICS.md, asserted: if the daemon could
    // answer it, this plane does not ask it.
    const c = clocked();
    c.move(1000);
    c.silent(7000);
    c.tel.input();
    c.move(200);
    for (const m of __pendingBatch().metrics) {
      expect(m.id).not.toMatch(/loss|rtt|tier|kbps|bitrate|fps/i);
    }
  });

  it('is inert after end(), so a late frame cannot reopen a closed session', () => {
    const c = clocked();
    c.move(1000);
    c.tel.end();
    c.move(1000);
    c.silent(9000);
    expect(__pendingBatch().metrics).toEqual([]);
  });
});
