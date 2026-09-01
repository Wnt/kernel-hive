// ============================================================================
//  analytics/streamEvents — the WebTransport/video plane's event vocabulary.
//  ---------------------------------------------------------------------------
//  WHAT WAS WRONG. The streaming plane — the thing this gallery IS — emitted
//  nothing to this plane. Not "too little": nothing. A quality switch existed
//  only folded into a 5-second periodic `stats` line, which is a SAMPLE and
//  can never say a switch HAPPENED. A decode error was caught, so
//  `errors.ts`'s window handler never saw it and `reportError` was never
//  called. `transport.ts` had zero emissions across all nine of its sites.
//  `retryBudget.ts`, `softwareDecodeLatch.ts`, `videoResume.ts` and
//  `resumePolicy.ts` were entirely uninstrumented, so a visitor permanently
//  demoted to software decode, or one whose retry budget had run out, left no
//  trace whatsoever.
//
//  THE SHAPE. One call — `emitStreamEvent(name, attrs, value)` — fans out to
//  everything this plane already has, so nobody instruments the same fact
//  twice and the four lanes cannot disagree about it:
//
//    a PROBE   the durable two-year count: does this happen at all, and how
//              often, per build and per client class
//    a METRIC  the bucketed distribution of the ONE number the event carries
//    a SPAN    named exactly as the event, opened as a child of whatever flow
//              is live, so the event lands INSIDE the journey it happened in
//    INSTANA   mirrored through `instanaStreamEvents.ts`, which is thin,
//              isolated and deletable — our plane is the product, the vendor
//              is a benchmark we intend to drop
//
//  ONE NUMBER PER EVENT, ON PURPOSE. `customMetric` is a single number and
//  the bucket ladders are three (`ms`, `count`, `pct`), so an event that
//  carried three numbers would have to pick one for the vendor and invent
//  ladders for the rest. It picks one HERE instead, declared in the table
//  below, and everything else numeric rides as a span attribute where it is
//  exact rather than bucketed.
//
//  SAMPLING, AND THE ONE RULE THAT IS NOT NEGOTIABLE. Every event declares
//  its own `sampleN` and the DECISION IS MADE ONCE — a sampled-away event
//  costs one increment and reaches no lane at all, so probe, metric, span and
//  vendor all describe the identical population and `n x sampleN` is the true
//  count for every one of them. The default is 1-in-1 and it is the right
//  default here: these events are RARE and DIAGNOSTIC. A quality switch, a
//  decode error, an exhausted budget and a software-decode latch happen a
//  handful of times per session at most, and sampling a rare event away is
//  how you get a report that says a fault does not happen. **An error is
//  never sampled.** Only two events are frequent enough to need a rate, and
//  both are levels rather than edges — see their rows.
//
//  PAGE BINDING (analytics/pageBinding.ts) is merged onto EVERY event here,
//  and it is the capability we have over the vendor: Instana's browser
//  `reportEvent` has no `viewName` — the mobile SDK has one, the browser one
//  does not — so a custom event there correlates to a page only implicitly.
//  Ours carries the route pattern and the page-load identity explicitly, so
//  "everything that happened on this page load" is an equality filter.
//
//  WHAT IS STILL NOT MEASURED HERE, and stays that way: loss, RTT, bitrate as
//  a distribution, encode time. The boundary docs/ANALYTICS.md sets holds —
//  if the daemon could answer it, this plane does not ask it. What is here is
//  the client's own DECISIONS and FAULTS, which the daemon cannot see.
// ============================================================================

import type { MetricId, ProbeId } from './catalogue';
import { METRICS } from './catalogue';
import { reach } from './index';
import { recordMetric } from './metrics';
import { reportError } from './errors';
import { childOfActive, type Attrs } from './trace';
import { pageBindingAttrs } from './pageBinding';
import { mirrorStreamEventToInstana } from './instanaStreamEvents';

/** One event in the vocabulary. `what`/`when`/`attrs` are the CONTRACT — the
 *  same three sentences docs/ANALYTICS.md §5.5 states — kept beside the code
 *  that emits it so the two cannot drift. */
export interface StreamEventSpec {
  /** What it means. Finish "this fired, therefore we know that…". */
  readonly what: string;
  /** When it fires — the exact edge, not the general area. */
  readonly when: string;
  /** The attribute keys this event carries beyond the page binding and the
   *  station dimensions. Declared so a test can prove every one of them
   *  survives `scripts/serve/traces.py` intake. */
  readonly attrs: readonly string[];
  /** 1 in this many is emitted. 1 = every one. */
  readonly sampleN: number;
  /** The durable count. */
  readonly probe: ProbeId;
  /** The bucketed distribution of this event's one number, if it has one. */
  readonly metric?: MetricId;
  /** Span status. `error` for the events that ARE a fault. */
  readonly status?: 'ok' | 'error';
  /** Also file it with `analytics/errors.ts`, so it is grouped by fingerprint
   *  and attributed to the open flow like any other fault. */
  readonly reportsError?: boolean;
}

export const STREAM_EVENTS = {
  // ---- quality (ABR) — the highest-value gap ------------------------------
  'stream.quality.switch': {
    what: 'the server moved this viewer to a different encoder tier or CRF',
    when: 'a KIND_PARAMS encoder-params record arrives whose tier, CRF or target bitrate differs from the one in force — the change itself, never a periodic sample of the current value',
    attrs: [
      'kh.quality.tierFrom', 'kh.quality.tierTo', 'kh.quality.crfFrom', 'kh.quality.crfTo',
      'kh.quality.targetKbps', 'kh.quality.width', 'kh.quality.height', 'kh.quality.fpsCap',
      'kh.quality.reason',
    ],
    sampleN: 1,
    probe: 'stream.quality.switch',
    metric: 'stream.quality.sinceLastSwitchMs',
  },
  // ---- decode -------------------------------------------------------------
  // NOT sampled, and it cannot storm: a VideoDecoder error is fatal to the
  // instance (state -> closed), so the next one cannot arrive until a
  // keyframe has rebuilt the decoder — the heartbeat is the natural floor.
  'stream.decode.error': {
    what: 'a WebCodecs configure or decode call failed',
    when: 'noteDecodeFailure — every failure, not the 1/s-throttled console line',
    attrs: ['error.type', 'kh.decode.consecutive', 'kh.decode.total', 'kh.decode.path', 'kh.decode.fatal'],
    sampleN: 1,
    probe: 'stream.decode.error',
    metric: 'stream.decode.errorRun',
    status: 'error',
    reportsError: true,
  },
  'stream.decode.rebuild': {
    what: 'a silently wedged decoder was dropped so the next key AU could build a fresh one',
    when: 'the ABR tick sees output stalled while AUs are still arriving — bounded at MAX_SILENT_STALL_REBUILDS per session',
    attrs: ['kh.decode.rebuild', 'kh.decode.rebuildMax'],
    sampleN: 1,
    probe: 'stream.decode.rebuild',
    status: 'error',
  },
  'stream.decode.softwareLatched': {
    what: 'this page will not ask for the hardware decoder again for the rest of its life',
    when: 'latchSoftwareDecode() flips the page-lifetime latch — at most once per document, which is why it is not sampled',
    attrs: ['kh.decode.cause'],
    sampleN: 1,
    probe: 'stream.decode.softwareLatched',
    status: 'error',
  },
  // ---- keyframes ----------------------------------------------------------
  // THE ONE SAMPLED EVENT IN THE VOCABULARY. A frame_id gap is a LEVEL on a lossy link, not an
  // edge: a congested minute produces them continuously, and at 1-in-1 this
  // is the one event here that could genuinely flood a collector. 1-in-10 is
  // the plane's existing precedent (streamClient/inputTrace.ts SAMPLE_N) and
  // the quantity being measured is a DISTRIBUTION of gap sizes, which
  // sampling does not bias.
  'stream.keyframe.gap': {
    what: 'frames were lost, so the decode gate is frozen on the last clean frame until a key AU heals the reference chain',
    when: 'auGate.noteGap() — a frame_id discontinuity in the incoming AU stream',
    attrs: ['kh.keyframe.gapFrames'],
    sampleN: 10,
    probe: 'stream.keyframe.gap',
    metric: 'stream.keyframe.gapFrames',
  },
  'stream.keyframe.timeout': {
    what: 'the transport came up and the first-frame budget expired with nothing painted',
    when: 'the keyframe watchdog rearms into a retry — once per attempt, so it is bounded by the retry budget and not sampled',
    attrs: ['kh.keyframe.budgetMs', 'kh.stream.live', 'kh.stream.restore'],
    sampleN: 1,
    probe: 'stream.keyframe.timeout',
    metric: 'stream.keyframe.waitMs',
    status: 'error',
  },
  // ---- audio --------------------------------------------------------------
  'stream.audio.start': {
    what: 'the first Opus sample actually reached the speakers on this session',
    when: 'the first AudioData the player schedules onto a running context — never at setup, which proves only that a decoder exists',
    attrs: ['kh.audio.sampleRate', 'kh.audio.ctxState'],
    sampleN: 1,
    probe: 'stream.audio.start',
    metric: 'stream.audio.toFirstSampleMs',
  },
  'stream.audio.blocked': {
    what: 'this visitor is watching a silent machine',
    when: 'AudioContext.resume() rejects, or audio is enabled onto a context that is not running — autoplay policy or a dead context',
    attrs: ['kh.audio.ctxState', 'error.type'],
    sampleN: 1,
    probe: 'stream.audio.blocked',
    status: 'error',
  },
  // ---- transport ----------------------------------------------------------
  'stream.transport.retry': {
    what: 'the connect ladder spent one attempt, and why',
    when: 'scheduleRetry — per retry. `station.open.attemptCount` is committed only on a painted frame, so a session that retried and never painted contributed nothing until this existed',
    attrs: ['kh.retry.attempt', 'kh.retry.limit', 'kh.retry.reason', 'kh.stream.live', 'kh.stream.restore'],
    sampleN: 1,
    probe: 'stream.transport.retry',
    metric: 'stream.transport.retryAttempt',
  },
  'stream.transport.exhausted': {
    what: 'the retry budget ran out — the session is over and the visitor has a poster or an error',
    when: 'consumeRetry reports `exhausted`. At most once per session by construction',
    attrs: ['kh.retry.attempt', 'kh.retry.limit', 'kh.stream.live'],
    sampleN: 1,
    probe: 'stream.transport.exhausted',
    status: 'error',
  },
  'stream.transport.closed': {
    what: 'the WebTransport session ended, and on which of the three terms',
    when: 'wt.closed resolves (clean server close), wt.closed rejects (QUIC error), or connect() throws before the session ever opened',
    attrs: ['kh.transport.reason'],
    sampleN: 1,
    probe: 'stream.transport.closed',
  },
  // ---- client-internal stalls --------------------------------------------
  'stream.stall.detected': {
    what: 'the picture stopped while the transport still looked healthy',
    when: 'the frame watchdog LATCHES — the edge only, so a stall that lasts a minute is one event and not six hundred',
    attrs: ['kh.stall.thresholdMs', 'kh.stall.hadDecodeError'],
    sampleN: 1,
    probe: 'stream.stall.detected',
    metric: 'stream.stall.sinceLastPaintMs',
    status: 'error',
  },
  // NOT SAMPLED, because it was made an EDGE instead. The keyframe watchdog
  // re-arms every RELIVE_KEYFRAME_WAIT_MS for as long as the sink stays
  // paused, so reporting the level would give a visitor who left a
  // backgrounded PWA for ten minutes two hundred identical events — and
  // sampling that down would have meant sampling a FAULT, which this plane
  // does not do. `sessionTelemetry` latches instead and a painted frame
  // clears the latch, so one pause episode is one event, the same discipline
  // `stream.stall.detected` uses.
  'stream.sink.paused': {
    what: 'nothing is CONSUMING a healthy stream — the <video> element is paused on a visible page',
    when: 'the keyframe watchdog first finds isPausedSink() true; re-armed only after a frame paints again',
    attrs: ['kh.sink.visible'],
    sampleN: 1,
    probe: 'stream.sink.paused',
    status: 'error',
  },
  // ---- coming back --------------------------------------------------------
  'stream.resume.decision': {
    what: 'the resume policy judged a backgrounded session live or dead, and on what evidence',
    when: 'sessionNeedsReconnect settles — once per tab foreground',
    attrs: ['kh.resume.verdict'],
    sampleN: 1,
    probe: 'stream.resume.decision',
    metric: 'stream.resume.probeMs',
  },
} as const satisfies Record<string, StreamEventSpec>;

export type StreamEventName = keyof typeof STREAM_EVENTS;

/** Per-event sampling counters. Free-running for the life of the tab, exactly
 *  like `inputTrace.ts`'s — the cost of an unsampled event is one increment
 *  and one comparison, no allocation and no id minted. */
const counters = new Map<string, number>();

function sampled(name: StreamEventName, sampleN: number): boolean {
  if (sampleN <= 1) return true;
  const next = (counters.get(name) ?? 0) + 1;
  if (next < sampleN) {
    counters.set(name, next);
    return false;
  }
  counters.set(name, 0);
  return true;
}

/**
 * Emit one stream event into every lane at once.
 *
 * `value` is the event's ONE number, as declared by its `metric` — bucketed
 * into our own distribution, carried exact on the span, and handed to Instana
 * as `customMetric`. Events with no declared metric ignore it.
 *
 * Never throws, on any path. Instrumentation that can break a stream is worse
 * than no instrumentation.
 */
export function emitStreamEvent(
  name: StreamEventName,
  attrs?: Attrs,
  value?: number,
): void {
  try {
    const spec = STREAM_EVENTS[name] as StreamEventSpec | undefined;
    if (!spec) return;
    if (!sampled(name, spec.sampleN)) return;

    // Call-site attributes FIRST: `trace.ts` caps at ATTR_MAX and keeps
    // insertion order, so if anything is dropped it is the page binding —
    // which is reconstructible from the trace — rather than the event's own
    // evidence, which is not.
    const all: Attrs = { ...attrs, ...pageBindingAttrs(), 'kh.sample.n': spec.sampleN };
    const numeric = typeof value === 'number' && Number.isFinite(value) && value >= 0
      ? value
      : undefined;
    if (spec.metric && numeric !== undefined) {
      const scale = (METRICS[spec.metric] as { scale?: string } | undefined)?.scale;
      // Same attribute name metrics.ts stamps on a timing's own span, so one
      // query reads both. A non-duration metric gets `kh.metric.n` rather
      // than being mislabelled as milliseconds.
      all[scale === 'ms' ? 'kh.metric.ms' : 'kh.metric.n'] = Math.round(numeric);
    }

    // A child of whatever flow is open (station.connect, session.resume,
    // stream.recover), so the event lands INSIDE the journey it happened in
    // rather than as an orphan beside it. Kind stays `internal`: this is the
    // tab observing itself, not a call waiting on the network, and inventing
    // an entry span to make a vendor's UI render differently is exactly the
    // design this plane rejected.
    const span = childOfActive(name, all, 'internal');
    span.end(spec.status ?? 'ok');

    reach(spec.probe);
    if (spec.metric && numeric !== undefined) recordMetric(spec.metric, numeric);
    // Grouped by fingerprint and blamed on the OPEN FLOW, which is the whole
    // point of errors.ts and is what a caught-and-console-logged decode
    // failure never reached.
    if (spec.reportsError) {
      reportError({ message: String(attrs?.['error.type'] ?? name), source: name });
    }

    mirrorStreamEventToInstana({
      name,
      timestamp: Date.now(),
      backendTraceId: span.traceId,
      meta: all,
      customMetric: numeric,
    });
  } catch {
    /* instrumentation never throws into the app */
  }
}

/** Test seam: forget every sampling counter. */
export function __resetStreamEventSampling(): void {
  counters.clear();
}
