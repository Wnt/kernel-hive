// Unit tests for the parts of the analytics plane that are pure logic: the
// intent ladder, the catalogue clamp, the flow funnel's monotonicity, and error
// fingerprinting. The transport is not tested here — it is fetch + timers, and
// the DOM-heavy half of the SPA is deliberately out of the vitest scope
// (vitest.config.ts). What IS tested is every rule that could quietly make the
// report say something false.

import { describe, expect, it, beforeEach } from 'vitest';
import { gradeFor, witnessHumanEdge, withoutHumanCredit, __resetIntent } from './intent';
import { beginFlow, currentFlow, __resetFlows } from './flows';
import { fingerprint, reportError, installErrorCapture } from './errors';
import { configureSink, __pendingBatch, __resetSink } from './sink';
import { __bufferedSpans, __resetTracer, configureTracer, popActive, pushActive, startTrace } from './trace';
import { PROBES, FLOWS } from './catalogue';
import { reach } from './index';

beforeEach(() => {
  __resetIntent();
  __resetFlows();
  __resetSink();
  __resetTracer();
  configureTracer({ enabled: true, emit: () => {} });
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
});

describe('intent grading', () => {
  it('never grades up: auto stays auto however much a human just did', () => {
    witnessHumanEdge();
    expect(gradeFor('auto')).toBe('auto');
  });

  it('refuses `act` with no recent human edge — a timer cannot claim credit', () => {
    expect(gradeFor('act')).toBe('show');
  });

  it('allows `act` right after a trusted edge', () => {
    witnessHumanEdge();
    expect(gradeFor('act')).toBe('act');
  });

  it('expires the credit, so a later timer does not inherit an old click', () => {
    witnessHumanEdge(Date.now() - 5000);
    expect(gradeFor('act')).toBe('show');
  });

  it('denies credit inside the synthetic bracket — a type-in demo is not typing', () => {
    witnessHumanEdge();
    withoutHumanCredit(() => {
      expect(gradeFor('act')).toBe('show');
    });
    // …and the bracket unwinds, so the click that STARTED the demo still counts.
    expect(gradeFor('act')).toBe('act');
  });

  it('downgrades `show` to `auto` when nobody is looking at the tab', () => {
    // The tests run under plain Node (vitest.config.ts), so there is no
    // `document` to hide — install one for the length of the assertion. This is
    // the rule that keeps a background tab pre-rendering a table out of the
    // "somebody saw this" column, so it is worth the four lines.
    const g = globalThis as { document?: unknown };
    g.document = { visibilityState: 'hidden' };
    try {
      expect(gradeFor('show')).toBe('auto');
      expect(gradeFor('act')).toBe('auto');
    } finally {
      delete g.document;
    }
  });
});

describe('the catalogue clamp', () => {
  it('holds an auto-only probe at auto even when a human just acted', () => {
    witnessHumanEdge();
    reach('fleet.usage.fetch', 'act');
    expect(__pendingBatch().probes).toEqual([{ id: 'fleet.usage.fetch', grade: 'auto', n: 1 }]);
  });

  it('falls to the strongest DECLARED grade below what it observed', () => {
    // stream.overlay.shown declares ['show']; an act-graded observation must
    // land on show, not be dropped and not be recorded as an act.
    witnessHumanEdge();
    reach('stream.overlay.shown', 'act');
    expect(__pendingBatch().probes).toEqual([{ id: 'stream.overlay.shown', grade: 'show', n: 1 }]);
  });

  it('drops an act-only probe when the evidence does not support an act', () => {
    reach('station.key.used', 'act'); // no witnessed human edge
    expect(__pendingBatch().probes).toEqual([]);
  });

  it('folds repeats into one counted row rather than one row each', () => {
    witnessHumanEdge();
    for (let i = 0; i < 5; i += 1) reach('station.key.used', 'act');
    expect(__pendingBatch().probes).toEqual([{ id: 'station.key.used', grade: 'act', n: 5 }]);
  });

  it('queues nothing at all before the sink is configured as allowed', () => {
    __resetSink();
    witnessHumanEdge();
    reach('station.key.used', 'act');
    expect(__pendingBatch().probes).toEqual([]);
  });
});

describe('flows', () => {
  it('reports entering the first step', () => {
    beginFlow('station.connect');
    expect(__pendingBatch().flows).toEqual([
      { flow: 'station.connect', step: 'open', outcome: 'enter', n: 1 },
    ]);
  });

  it('ignores backwards and repeated steps, so the funnel stays a funnel', () => {
    const f = beginFlow('station.connect');
    f.step('firstFrame');
    f.step('transport'); // backwards
    f.step('firstFrame'); // repeat
    const steps = __pendingBatch().flows.filter((r) => r.outcome === 'enter').map((r) => r.step);
    expect(steps).toEqual(['open', 'firstFrame']);
  });

  it('finishes exactly once — a fail in catch then an ok in finally is one row', () => {
    const f = beginFlow('station.connect');
    f.fail('nolive');
    f.ok();
    const outcomes = __pendingBatch().flows.filter((r) => r.outcome !== 'enter');
    expect(outcomes).toEqual([{ flow: 'station.connect', step: 'nolive', outcome: 'fail', n: 1 }]);
  });

  it('close() leaves the stack and reports nothing — abandonment is not a fault', () => {
    const f = beginFlow('station.connect');
    f.close();
    expect(currentFlow()).toBeNull();
    expect(__pendingBatch().flows.filter((r) => r.outcome !== 'enter')).toEqual([]);
  });

  it('exposes the open flow so an error can be blamed on it', () => {
    const f = beginFlow('station.connect');
    f.step('transport');
    // Field-wise, not toEqual: an OpenFlow also carries its trace spans now,
    // and pinning the whole object would make every future field a test edit.
    expect(currentFlow()).toMatchObject({ flow: 'station.connect', step: 'transport' });
    f.ok();
    expect(currentFlow()).toBeNull();
  });
});

describe('error fingerprinting', () => {
  it('collapses the same fault against different stations into one row', () => {
    const a = fingerprint('Failed to fetch https://lab:8443/signal/beos.json', 'promise');
    const b = fingerprint('Failed to fetch https://lab:8443/signal/irix.json', 'promise');
    expect(a).toBe(b);
  });

  it('collapses line numbers and sizes, which differ per build', () => {
    expect(fingerprint('chunk 4821 failed', 'window')).toBe(fingerprint('chunk 91 failed', 'window'));
  });

  it('keeps genuinely different faults apart', () => {
    expect(fingerprint('decoder gave up', 'window')).not.toBe(fingerprint('transport closed', 'window'));
  });

  it('mixes the source in, so a numeric-only message is still distinguishable', () => {
    expect(fingerprint('500', 'window')).not.toBe(fingerprint('500', 'promise'));
  });
});

describe('reporting an error', () => {
  it('queues one grouped row carrying the fingerprint it returns', () => {
    const fp = reportError({ message: 'decoder gave up', source: 'window' });
    const [row] = __pendingBatch().errors;
    expect(row.fp).toBe(fp);
    expect(row.message).toBe('decoder gave up');
    expect(row.source).toBe('window');
  });

  it('blames the flow that was open, and the step it stood on', () => {
    const f = beginFlow('station.connect');
    f.step('transport');
    reportError({ message: 'boom', source: 'promise' });
    const [row] = __pendingBatch().errors;
    expect(row.flow).toBe('station.connect');
    expect(row.step).toBe('transport');
    f.ok();
  });

  it('still records an error that belongs to no flow', () => {
    // "Faults nobody's flow owns" is a finding in itself — a crash on the
    // landing page has no flow and must not vanish for lack of one.
    reportError({ message: 'boom', source: 'window' });
    const [row] = __pendingBatch().errors;
    expect(row.flow).toBeUndefined();
  });

  it('attaches an OTel exception event to the span that was running', () => {
    // This is what turns "this fingerprint happened 40 times" into "open one
    // and see the journey it happened inside".
    const span = startTrace('station.connect');
    pushActive(span);
    const fp = reportError({ message: 'transport closed', source: 'promise' });
    popActive(span);
    span.end('error');
    const [wire] = __bufferedSpans();
    expect(wire.e?.[0].n).toBe('exception');
    expect(wire.e?.[0].a).toMatchObject({
      'exception.type': 'promise',
      'exception.message': 'transport closed',
      'kh.fingerprint': fp,
    });
    expect(wire.a!['error.type']).toBe('promise');
  });

  it('truncates a long message rather than storing a log line', () => {
    reportError({ message: 'x'.repeat(5000), source: 'window' });
    expect(__pendingBatch().errors[0].message.length).toBeLessThanOrEqual(200);
  });

  it('never throws, even when there is no span and no flow and no sink', () => {
    __resetSink();
    expect(() => reportError({ message: 'boom', source: 'window' })).not.toThrow();
  });

  it('installErrorCapture is idempotent and safe without a window', () => {
    expect(() => { installErrorCapture(); installErrorCapture(); }).not.toThrow();
  });
});

describe('the catalogue itself', () => {
  it('declares at least one grade for every probe — a probe with none is unreportable', () => {
    const probes = PROBES as Record<string, { grades: readonly string[] }>;
    for (const [id, spec] of Object.entries(probes)) {
      expect(spec.grades.length, `${id} declares no grades`).toBeGreaterThan(0);
    }
  });

  it('only ever consumes a declared `auto` producer', () => {
    const all = PROBES as Record<string, { grades: readonly string[]; consumes?: string }>;
    for (const [id, spec] of Object.entries(all)) {
      const from = spec.consumes;
      if (!from) continue;
      expect(PROBES, `${id} consumes an undeclared probe`).toHaveProperty(from);
      expect((PROBES as Record<string, { grades: readonly string[] }>)[from].grades)
        .toContain('auto');
    }
  });

  it('gives every flow at least two steps — a one-step funnel measures nothing', () => {
    const flows = FLOWS as Record<string, { steps: readonly string[] }>;
    for (const [id, spec] of Object.entries(flows)) {
      expect(spec.steps.length, `${id} is not a funnel`).toBeGreaterThan(1);
    }
  });
});
