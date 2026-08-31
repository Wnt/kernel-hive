// ============================================================================
//  analytics/flows — a named path through the gallery, and where it dies.
//  ---------------------------------------------------------------------------
//  "How many errors happen in each user flow" is not answerable from an error
//  log, because an error log knows what broke and not what the person was
//  trying to do. So a flow is opened around the attempt, its steps are reported
//  as they are passed, and any error raised while it is open is attributed to
//  the flow and the step it was standing on. The same exception thrown from the
//  same line is a different finding depending on whether it killed a connect or
//  a poster page turn, and only the flow knows which.
//
//  NO TIMEOUTS, NO ABANDON EVENT. A flow that is never finished reports its
//  steps and then stops, and the report reads the drop-off straight out of the
//  funnel: 300 entered `transport`, 210 reached `firstFrame`, so 90 sessions
//  died in the transport step. Synthesising an "abandoned" event on a timer
//  would only invent a number the funnel already states, and would have to
//  guess a threshold to do it.
//
//  STEPS ARE MONOTONIC. Reporting step N implies 1..N-1 were passed, so a call
//  site does not have to report every step to keep the funnel honest, and a
//  retry loop that re-enters a step counts once per flow instance. That makes
//  the funnel a funnel — counts that only ever decrease down the list — rather
//  than a bag of counters that can read 210 firstFrames against 40 transports.
//
//  A FLOW IS ALSO A TRACE. Every flow opens an OTel trace whose root span is
//  the flow and whose children are its steps, so the same call that feeds the
//  funnel feeds the drilldown — nobody has to instrument twice, and the two can
//  never disagree about what happened. The funnel is what you read to see WHERE
//  attempts die; the trace is what you open to see WHY one of them did.
//
//  The counter half still stands on its own: it is bucketed, anonymous and kept
//  for two years, while traces carry a session id and expire in days. Losing
//  the traces to retention must not lose the funnel, which is why they are two
//  lanes and not one.
//
//  A FLOW IS NOT A SPAN — it counts attempts, it does not time them. Journey
//  timing lives in metrics.ts, deliberately as its own lane: a flow's job is to
//  say WHERE an attempt died, and fusing a duration into it would mean every
//  step boundary had to be both a funnel edge and a clock edge, which is how
//  you end up unable to change one without moving the other. A call site that
//  wants both opens a flow and a timing, and they are independent.
//
//  What still does NOT belong on either: stream latency. The Ctrl+N overlay,
//  clientlog's 5-second stats line and the daemon's journal already measure
//  encode/transport/decode, and a fourth number here would only disagree with
//  all three. The boundary is: if the daemon could answer it, this plane does
//  not ask it.
// ============================================================================

import { FLOWS, type FlowId, type FlowStep } from './catalogue';
import { queueFlow } from './sink';
import { popActive, pushActive, startTrace, type Attrs, type Span } from './trace';

/** The innermost open flow, for error attribution. */
export interface OpenFlow {
  readonly flow: FlowId;
  step: string;
  /** The flow's root span, and the span for the step it is standing on. */
  readonly root: Span;
  stepSpan: Span | null;
}

/** A live flow attempt. Finish it exactly once — later calls are ignored, so a
 *  `fail` in a catch block followed by an `ok` in a `finally` cannot report
 *  both. */
export interface FlowHandle {
  /** Advance to `step`. Backwards and repeat moves are ignored (see above). */
  step(step: FlowStep<FlowId> | string): void;
  /** The flow completed. */
  ok(): void;
  /** The flow died here. `reason` is a short stable token, never a message. */
  fail(reason?: string): void;
  /** Leave the stack without reporting anything — for a call site TORN DOWN
   *  rather than finished (a React effect cleanup, a cancelled attempt). It is
   *  not a failure: the visitor navigating away is already visible as the
   *  funnel's drop-off, and reporting it as `fail` would double-count every
   *  abandonment as a fault. Not calling it at all is the real bug — the open
   *  stack is bounded, so a leak silently stops attributing errors. */
  close(): void;
  /**
   * Attach `attrs` to every span this flow opens from now on — the root, the
   * CURRENT step span, and every step span opened after this call. For
   * grouping dimensions (analytics/stationAttrs.ts) a caller does not yet
   * have at `beginFlow()` time, or does not want baked into the call site's
   * literal text — `scripts/analytics/catalogue.mjs`'s flow gate greps for
   * the EXACT text `beginFlow('<id>')`, so a call site that always passes a
   * second argument there would read as an undeclared flow. `tag()` is the
   * escape hatch: open bare, tag once the station is known.
   */
  tag(attrs: Attrs): void;
}

/** Open flows, innermost last. Bounded so a leaking call site cannot grow it. */
const stack: OpenFlow[] = [];
const MAX_OPEN = 8;

const NOOP: FlowHandle = { step() {}, ok() {}, fail() {}, close() {}, tag() {} };

/** The flow an error should be blamed on, if any. */
export function currentFlow(): OpenFlow | null {
  return stack.length ? stack[stack.length - 1] : null;
}

/**
 * Begin one attempt at `flow`. Always returns a handle; never throws.
 *
 * `attrs` are merged onto the flow's root span AND every step span it opens —
 * not just the root — because a consumer that reads spans individually
 * (Instana's Unbounded Analytics, `/admin/observability`'s own span list)
 * must not have to walk up to a parent to learn what STATION a span belongs
 * to. Typically `stationAttrs(...)` (analytics/stationAttrs.ts): station id
 * plus the low-cardinality type dimensions a report groups by.
 */
export function beginFlow(flow: FlowId, attrs?: Attrs): FlowHandle {
  try {
    const spec = FLOWS[flow];
    if (!spec || stack.length >= MAX_OPEN) return NOOP;
    // Mutable so `tag()` can grow it after the fact; every span opened from
    // here on (including ones already open) picks up whatever is in it.
    const tagAttrs: Attrs = { ...attrs };
    // `kh.flow` rather than a bare name: the semantic conventions have no term
    // for "a named journey through a UI", so it is namespaced to say plainly
    // that it is ours and will not collide with a convention added later.
    const root = startTrace(flow, { 'kh.flow': flow, ...tagAttrs });
    pushActive(root);
    const open: OpenFlow = { flow, step: spec.steps[0], root, stepSpan: null };
    open.stepSpan = root.child(`${flow}.${open.step}`, { 'kh.step': open.step, ...tagAttrs });
    stack.push(open);
    queueFlow(flow, open.step, 'enter');
    let done = false;
    const close = (outcome: 'ok' | 'fail', reason?: string) => {
      if (done) return;
      done = true;
      const at = stack.lastIndexOf(open);
      if (at >= 0) stack.splice(at, 1);
      open.stepSpan?.end(outcome === 'fail' ? 'error' : 'ok');
      open.stepSpan = null;
      popActive(open.root);
      // The reason token lands as `error.type`, which is the OTel attribute a
      // trace UI groups failures by — so "why did connects fail this week"
      // is one facet, not a string search.
      open.root.end(
        outcome === 'fail' ? 'error' : 'ok',
        outcome === 'fail' && reason ? { 'error.type': reason } : undefined,
      );
      queueFlow(flow, outcome === 'fail' ? (reason || open.step) : open.step, outcome);
    };
    return {
      step(next: string) {
        try {
          if (done) return;
          const steps = spec.steps as readonly string[];
          const from = steps.indexOf(open.step);
          const to = steps.indexOf(next);
          // An unknown step is reported as-is but does not move the funnel
          // position: the catalogue is the funnel's shape, not the call site.
          if (to < 0) return queueFlow(flow, next, 'enter');
          if (to <= from) return;
          // One span per step, closed as the next opens: that is what makes the
          // flame graph show where the time in a journey actually went.
          open.stepSpan?.end('ok');
          open.step = next;
          open.stepSpan = open.root.child(`${flow}.${next}`, { 'kh.step': next, ...tagAttrs });
          queueFlow(flow, next, 'enter');
        } catch { /* never throw out of instrumentation */ }
      },
      ok() { try { close('ok'); } catch { /* noop */ } },
      fail(reason?: string) { try { close('fail', reason); } catch { /* noop */ } },
      close() {
        try {
          if (done) return;
          done = true;
          const at = stack.lastIndexOf(open);
          if (at >= 0) stack.splice(at, 1);
          // Abandoned, not failed: the span closes `unset` so it is neither
          // green nor red in a trace list. Reporting it as an error would make
          // every visitor who navigated away look like a fault.
          open.stepSpan?.end('unset');
          open.stepSpan = null;
          popActive(open.root);
          open.root.end('unset', { 'kh.abandoned': true });
        } catch { /* noop */ }
      },
      tag(newAttrs: Attrs) {
        try {
          if (done) return;
          Object.assign(tagAttrs, newAttrs);
          for (const [k, v] of Object.entries(newAttrs)) {
            open.root.attr(k, v);
            open.stepSpan?.attr(k, v);
          }
        } catch { /* noop */ }
      },
    };
  } catch {
    return NOOP;
  }
}

/** Test seam: drop every open flow. */
export function __resetFlows(): void {
  stack.length = 0;
}
