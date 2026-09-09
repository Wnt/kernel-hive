// ============================================================================
//  analytics — the public API. Three calls, and one of them is the setup.
//  ---------------------------------------------------------------------------
//    reach('fleet.usage.shown', 'show')   this feature was used, this deliberately
//    beginFlow('station.connect')         this attempt started; report its steps
//    startTiming('station.open.toFirstFrameMs')   this took a while; how long
//    recordMetric('fleet.find.hScrollPx', px)     this cost effort; how much
//    reportError({ message, source })     this fault happened, blame the open flow
//
//  Everything else — batching, grading, classification, fingerprinting — is
//  deliberately invisible at the call site. An instrumentation API that asks
//  the caller to think does not get called, and a probe that is not called is
//  a zero that lies (see catalogue.ts).
//
//  WHY NOT JUST EXTEND /clientlog OR /usage. Both already exist and neither
//  answers this question. /clientlog is a rolling window of raw session
//  evidence pruned by AGE — the right shape for debugging one stream, the wrong
//  shape for a year-over-year "does anyone use this", which needs a durable
//  aggregate that outlives the window. /usage counts clicks and keystrokes PER
//  STATION, which is the museum's exhibit-popularity question and says nothing
//  about the software: it cannot tell you that the fleet table's filter row is
//  dead code. This is the third question, and it gets the third plane rather
//  than a fourth meaning bolted onto one of the first two.
// ============================================================================

import { BUILD_ID } from './build';
import { PROBES, type ProbeId } from './catalogue';
import { clientClass, gradeFor, installIntentWitness, type Intent } from './intent';
import { configureSink, queueProbe } from './sink';
import { installErrorCapture } from './errors';
import { configureTracer, requeueSpans, type WireSpan } from './trace';
import { postTelemetry } from './beacon';

// Only what CALL SITES use. `fingerprint`, `witnessHumanEdge` and the flush are
// exported by their own modules for the tests and the operator plane;
// re-exporting them here would make this barrel a list of everything that
// exists rather than a description of the API.
export { beginFlow } from './flows';
export { startTiming, accumulator, recordMetric } from './metrics';
export type { Timing } from './metrics';
export { reportError } from './errors';
export { withoutHumanCredit } from './intent';

/** Weakest to strongest; the index IS the ordering. */
const LADDER: readonly Intent[] = ['auto', 'show', 'act'];

/**
 * Report that an instrumented feature was reached.
 *
 * `want` is what the CALL SITE believes it is observing; what gets recorded is
 * what the evidence actually supports, which can be weaker — a render into a
 * hidden tab is `auto`, not `show`, and the call site does not have to know
 * that. It is then clamped to the grades the catalogue declares for this probe,
 * so a probe declared `['auto']` can never be inflated to an `act` by a call
 * site that moved. Both narrowings are one-way: nothing here can grade UP.
 */
export function reach(id: ProbeId, want: Intent = 'auto'): void {
  try {
    const spec = PROBES[id];
    if (!spec) return;
    const observed = gradeFor(want);
    const allowed = spec.grades as readonly Intent[];
    if (allowed.includes(observed)) return queueProbeGrade(id, observed);
    // Not declared at this grade: fall to the strongest DECLARED grade weaker
    // than what we saw, and drop it entirely if the probe declares none.
    for (let i = LADDER.indexOf(observed) - 1; i >= 0; i -= 1) {
      if (allowed.includes(LADDER[i])) return queueProbeGrade(id, LADDER[i]);
    }
  } catch { /* instrumentation never throws into the app */ }
}

function queueProbeGrade(id: string, grade: Intent): void {
  queueProbe(id, grade);
}

/**
 * Start the plane. Called once from main.tsx AFTER the session is resolved,
 * with the same `allowed` answer the /clientlog gate uses: a signed-out
 * stranger at the walk-in signup door has no session, so every flush would 401
 * and re-queue forever.
 */
export function initAnalytics(opts: {
  sessionId: string;
  allowed: boolean;
  /** The signed-in account, when there is one. Stamped on the span that enters
   *  each trace as the OTel `enduser.id` / `user.name` / `enduser.role`
   *  attributes — see `trace.ts`'s `identity`, and docs/ANALYTICS.md §0 for
   *  why this plane carries identity at all. */
  user?: { id: string; name: string; role: string };
}): void {
  try {
    installIntentWitness();
    configureSink({ sessionId: opts.sessionId, allowed: opts.allowed, clientClass });
    configureTracer({
      enabled: opts.allowed,
      emit: (spans, final) => postSpans(opts.sessionId, spans, final),
      identity: opts.user
        ? {
            'enduser.id': opts.user.id,
            'enduser.role': opts.user.role,
            ...(opts.user.name ? { 'user.name': opts.user.name } : {}),
          }
        : undefined,
    });
    if (opts.allowed) installErrorCapture();
  } catch { /* a gallery that loads beats a gallery that measures */ }
}

/**
 * Ship one batch of spans. Its own endpoint, not `/analytics`, because the two
 * differ in every way that matters operationally: spans are kilobytes where
 * counters are integers, they expire in days where counters last two years, and
 * they are admin-only to READ where the aggregates are open. One route serving
 * both would have to take the strictest of each, and the counters would lose
 * their openness to a constraint that is not theirs.
 *
 * The RESOURCE goes on the envelope rather than on every span — it is identical
 * for all of them, and OTLP itself groups spans under one Resource for exactly
 * this reason (serve/traces.py re-expands it on export).
 */
function postSpans(sessionId: string, spans: WireSpan[], final = false): void {
  try {
    if (!spans.length) return;
    const body = JSON.stringify({
      resource: {
        'service.name': 'kernel-hive-spa',
        'session.id': sessionId,
        'kh.class': clientClass(),
        // WHICH BUNDLE THIS CLIENT IS RUNNING — a RESOURCE attribute, not a
        // per-span one: it is identical for every span a tab will ever emit,
        // which is exactly what a Resource is for. serve/traces.py stores it on
        // the trace row and traces_otlp.py exports it as `service.version`.
        // Before this existed the only place a build id was recorded was a
        // vendor beacon's `kh.bundle` meta, so "was that phone on an old
        // shell?" was unanswerable without the vendor — see
        // docs/ANALYTICS.md §"Which bundle was this client running".
        'kh.bundle': BUILD_ID,
      },
      spans,
    });
    // NO `traceparent`: see sink.ts. `/traces` is not even traced server-side
    // (tracing_http.py's allowlist refuses the telemetry ingest on purpose), so
    // the header could only ever have been a parent nothing recorded.
    //
    // `keepalive` ONLY on the final flush, and the batch is KEPT when there was
    // no answer — both of those are `analytics/beacon.ts`, and both were bought
    // by the same measured fault. This route used to post every batch with
    // `keepalive: true` and drop it on failure; a document's keepalive
    // allowance is 64 KiB spent once, so a tab went silent on `/traces`,
    // `/analytics`, `/clientlog` and `/logs` in the same second, permanently,
    // while the daemon's half of every input trace kept landing without its
    // root. 38% of `input.dispatch` spans over 24 h were orphaned that way.
    void postTelemetry('/traces', body, { final }).then((result) => {
      if (result === 'failed') requeueSpans(spans);
    });
  } catch { /* never throw */ }
}
