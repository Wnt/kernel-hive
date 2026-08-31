// Tests for the walk-in lane. Every one of these guards a way the walk-in
// numbers could read as confident and be wrong: an exhausted pool and a healthy
// one folded into one distribution, a fence counted as a lost visitor, a
// working feature counted as friction, an abandoned effect inventing a zero.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { registerRefused, registerTelemetry } from './registerTelemetry';
import { playTelemetry } from './playTelemetry';
import { __resetMetrics } from '../analytics/metrics';
import { __resetFlows } from '../analytics/flows';
import { __resetIntent } from '../analytics/intent';
import { configureSink, __pendingBatch, __resetSink } from '../analytics/sink';

/** A `document` stand-in: these tests run under plain Node (vitest.config.ts),
 *  so the hesitation listener and the visibility clock have nothing to attach
 *  to unless one is supplied. */
function installDocument() {
  const listeners = new Map<string, Set<(e: unknown) => void>>();
  (globalThis as { document?: unknown }).document = {
    visibilityState: 'visible',
    addEventListener: (type: string, fn: (e: unknown) => void) => {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type)!.add(fn);
    },
    removeEventListener: (type: string, fn: (e: unknown) => void) => {
      listeners.get(type)?.delete(fn);
    },
  };
  return {
    fire(type: string, isTrusted = true) {
      for (const fn of [...(listeners.get(type) ?? [])]) fn({ isTrusted });
    },
    count(type: string) { return listeners.get(type)?.size ?? 0; },
  };
}

beforeEach(() => {
  __resetMetrics();
  __resetFlows();
  __resetIntent();
  __resetSink();
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
});

afterEach(() => { delete (globalThis as { document?: unknown }).document; });

const metric = (id: string) => __pendingBatch().metrics.filter((m) => m.id === id);
const probe = (id: string) => __pendingBatch().probes.filter((p) => p.id === id);
const flowOf = (id: string) => __pendingBatch().flows.filter((f) => f.flow === id);

// =============================================================================
//  walkin.play — the poolSize argument
// =============================================================================

describe('the queue / instant split', () => {
  it('an instant claim records the instant probe and NO queue duration', () => {
    // The two are not one distribution with a zero in it: an instant claim is
    // the ABSENCE of a queue, and folding them together is exactly how an
    // exhausted pool and a healthy one produce the same picture.
    const t = playTelemetry();
    t.claiming();
    t.held();
    t.drove();
    t.ended();
    expect(probe('walkin.play.claimInstant')).toHaveLength(1);
    expect(probe('walkin.play.claimQueued')).toHaveLength(0);
    expect(metric('walkin.play.queueMs')).toEqual([]);
  });

  it('a queued claim records the queue duration and NOT the instant probe', () => {
    const t = playTelemetry();
    t.claiming();
    t.queued();
    t.claiming();
    t.held();
    t.drove();
    t.ended();
    expect(probe('walkin.play.claimQueued')).toHaveLength(1);
    expect(probe('walkin.play.claimInstant')).toHaveLength(0);
    expect(metric('walkin.play.queueMs')).toHaveLength(1);
  });

  it('measures the WHOLE wait across retries, not the last leg of it', () => {
    // A visitor who pressed "Try again" three times waited once. Restarting the
    // clock per attempt would report the wait as however long the last press
    // took, which is a number about the broker rather than about the visitor.
    const t = playTelemetry();
    t.claiming();
    t.queued();
    t.claiming();
    t.queued();
    t.claiming();
    t.held();
    t.ended();
    expect(metric('walkin.play.queueMs')).toHaveLength(1);
    // Both queue answers are counted; the CLOCK is one.
    expect(probe('walkin.play.claimQueued')[0].n).toBe(2);
  });

  it('drops the queue clock when the visitor leaves the queue', () => {
    const t = playTelemetry();
    t.claiming();
    t.queued();
    t.ended();
    // Not a zero-length wait — an unfinished one. A zero here would be the
    // fastest queue in the distribution and there is no such queue.
    expect(metric('walkin.play.queueMs')).toEqual([]);
  });
});

describe('claim retries', () => {
  it('counts a second press of Play, not the first', () => {
    const t = playTelemetry();
    t.claiming();
    t.queued();
    t.claiming();
    t.held();
    t.ended();
    expect(metric('walkin.play.claimRetries')).toEqual([
      { id: 'walkin.play.claimRetries', bucket: '1', n: 1 },
    ]);
  });

  it('does NOT count a reset — the visitor asked for a fresh machine and got one', () => {
    // Counting a feature working as friction is how a good feature gets
    // "fixed". A reset is the walk-in plane doing exactly what it promises.
    const t = playTelemetry();
    t.claiming();
    t.held();
    t.claiming({ reset: true });
    t.held();
    t.ended();
    expect(metric('walkin.play.claimRetries')).toEqual([
      { id: 'walkin.play.claimRetries', bucket: '1', n: 1 },
    ]);
  });

  it('records the ZERO — one press was enough is the outcome the pool is for', () => {
    const t = playTelemetry();
    t.claiming();
    t.held();
    t.ended();
    expect(metric('walkin.play.claimRetries')).toEqual([
      { id: 'walkin.play.claimRetries', bucket: '1', n: 1 },
    ]);
  });
});

describe('to a machine the visitor actually drives', () => {
  it('records nothing for a clone that was handed over and never touched', () => {
    // A clone that painted perfectly and was never driven is one the pool spent
    // for nothing. It shows up as a funnel that reached `held` and not `driven`
    // — never as a fast toPlayableMs.
    const t = playTelemetry();
    t.claiming();
    t.held();
    t.ended();
    expect(metric('walkin.play.toPlayableMs')).toEqual([]);
    expect(flowOf('walkin.play').some((f) => f.step === 'driven')).toBe(false);
  });

  it('records once, however many times the visitor touches the machine', () => {
    const t = playTelemetry();
    t.claiming();
    t.held();
    t.drove();
    t.drove();
    t.drove();
    t.ended();
    expect(metric('walkin.play.toPlayableMs')).toHaveLength(1);
    expect(metric('walkin.play.toPlayableMs')[0].n).toBe(1);
  });

  it('separates a closed door from a broker that could not produce a machine', () => {
    const shut = playTelemetry();
    shut.claiming();
    shut.refused();
    shut.ended();
    expect(flowOf('walkin.play').some((f) => f.outcome === 'fail' && f.step === 'closed')).toBe(true);
  });
});

// =============================================================================
//  walkin.register — the door
// =============================================================================

describe('refusal is not abandonment', () => {
  it('counts a closed door as its own fact, with no flow at all', () => {
    // If a refused stranger entered the funnel, the drop-off at `landing` would
    // read as a landing page nobody understands, and somebody would rewrite
    // copy to fix an operator switch.
    registerRefused();
    expect(probe('walkin.register.refused')).toHaveLength(1);
    expect(flowOf('walkin.register')).toHaveLength(0);
  });

  it('fails a browser with no passkey support with its OWN reason', () => {
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.unsupported();
    expect(flowOf('walkin.register').some((f) => f.outcome === 'fail' && f.step === 'nopasskey')).toBe(true);
    // …and it records no stage durations: nothing was attempted, so a duration
    // would be a measurement of a stage that never ran.
    expect(metric('walkin.register.hesitationMs')).toEqual([]);
    expect(metric('walkin.register.landingMs')).toEqual([]);
  });
});

describe('hesitation', () => {
  it('stops at the visitor\'s first trusted act on the page', () => {
    const doc = installDocument();
    const t = registerTelemetry();
    t.landed();
    expect(doc.count('pointerdown')).toBe(1);
    doc.fire('pointerdown');
    expect(metric('walkin.register.hesitationMs')).toHaveLength(1);
    // …and it stops listening, so a second click cannot record a second sample.
    doc.fire('pointerdown');
    expect(metric('walkin.register.hesitationMs')).toHaveLength(1);
  });

  it('ignores an untrusted event — dispatched input is software, not a person', () => {
    const doc = installDocument();
    const t = registerTelemetry();
    t.landed();
    doc.fire('pointerdown', false);
    expect(metric('walkin.register.hesitationMs')).toEqual([]);
    t.abandoned();
  });

  it('records nothing for a visitor who arrived and left without touching it', () => {
    // An abandoned effect is not a zero-length hesitation. Enough invented
    // zeros and the door would look effortless precisely because nobody used it.
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.abandoned();
    expect(metric('walkin.register.hesitationMs')).toEqual([]);
    expect(flowOf('walkin.register').some((f) => f.outcome === 'fail')).toBe(false);
  });
});

describe('the passkey stage', () => {
  it('counts retries as attempts BEYOND the first', () => {
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.passkeyStarted();
    t.passkeyStarted();
    t.passkeyStarted();
    t.accountReady();
    expect(metric('walkin.register.passkeyRetries')).toEqual([
      { id: 'walkin.register.passkeyRetries', bucket: '2', n: 1 },
    ]);
  });

  it('times the STAGE, not the successful attempt', () => {
    // Three cancelled sheets and a fourth that works is one stage that took a
    // long time; timing each attempt would report the fourth as a fast passkey.
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.passkeyStarted();
    t.passkeyStarted();
    t.accountReady();
    expect(metric('walkin.register.passkeyMs')).toHaveLength(1);
  });

  it('records no retry count for a visitor who never started a ceremony', () => {
    // A zero from somebody who never entered the stage is a zero about nothing,
    // and a floor of them would hide a real enrolment problem.
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.abandoned();
    expect(metric('walkin.register.passkeyRetries')).toEqual([]);
  });
});

describe('the two paths through the door', () => {
  it('one tap (machine first) records NO picking stage — there was none', () => {
    // Recording a zero here would invent a stage the visitor never stood in,
    // and the picking distribution would become mostly that invention.
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.chose();
    t.passkeyStarted();
    t.accountReady();
    t.reachedMachine();
    expect(metric('walkin.register.exhibitPickMs')).toEqual([]);
    expect(metric('walkin.register.landingMs')).toHaveLength(1);
  });

  it('passkey first records the picking stage, because it exists', () => {
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.passkeyStarted();
    t.accountReady();
    t.chose();
    t.reachedMachine();
    expect(metric('walkin.register.exhibitPickMs')).toHaveLength(1);
  });

  it('reports the funnel in ONE order on both paths', () => {
    // The funnel has one order or it is not a funnel; `machine` is reported
    // when the visitor is SENT to one, which on both paths is after the account.
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.chose();
    t.passkeyStarted();
    t.accountReady();
    t.reachedMachine();
    const steps = flowOf('walkin.register').filter((f) => f.outcome === 'enter').map((f) => f.step);
    expect(steps).toEqual(['landing', 'passkey', 'account', 'machine']);
    expect(flowOf('walkin.register').some((f) => f.outcome === 'ok')).toBe(true);
  });

  it('settles once — an abandon after arriving cannot un-complete the attempt', () => {
    installDocument();
    const t = registerTelemetry();
    t.landed();
    t.passkeyStarted();
    t.accountReady();
    t.reachedMachine();
    t.abandoned();
    expect(flowOf('walkin.register').filter((f) => f.outcome === 'ok')).toHaveLength(1);
  });
});
