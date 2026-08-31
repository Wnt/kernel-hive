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
//  A FLOW IS NOT A SPAN. Nothing here measures time. Latency already has three
//  better sources in this repo (the Ctrl+N overlay, clientlog's 5-second stats
//  line, the daemon's own journal) and duplicating it badly here would produce
//  a fourth number that disagrees with all of them.
// ============================================================================

import { FLOWS, type FlowId, type FlowStep } from './catalogue';
import { queueFlow } from './sink';

/** The innermost open flow, for error attribution. */
export interface OpenFlow {
  readonly flow: FlowId;
  step: string;
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
}

/** Open flows, innermost last. Bounded so a leaking call site cannot grow it. */
const stack: OpenFlow[] = [];
const MAX_OPEN = 8;

const NOOP: FlowHandle = { step() {}, ok() {}, fail() {}, close() {} };

/** The flow an error should be blamed on, if any. */
export function currentFlow(): OpenFlow | null {
  return stack.length ? stack[stack.length - 1] : null;
}

/** Begin one attempt at `flow`. Always returns a handle; never throws. */
export function beginFlow(flow: FlowId): FlowHandle {
  try {
    const spec = FLOWS[flow];
    if (!spec || stack.length >= MAX_OPEN) return NOOP;
    const open: OpenFlow = { flow, step: spec.steps[0] };
    stack.push(open);
    queueFlow(flow, open.step, 'enter');
    let done = false;
    const close = (outcome: 'ok' | 'fail', reason?: string) => {
      if (done) return;
      done = true;
      const at = stack.lastIndexOf(open);
      if (at >= 0) stack.splice(at, 1);
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
          open.step = next;
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
