// ============================================================================
//  analytics/catalogue/stream — the WebTransport/video plane's own vocabulary.
//  ---------------------------------------------------------------------------
//  Everything here was DARK until 2026-09-01. The streaming plane had exactly
//  three kinds of evidence and none of them was an event: a 5-second periodic
//  `stats` line in /clientlog (a SAMPLE — it can tell you the tier was 3 at
//  12:04:05 and never that it CHANGED), a console.error nobody can read from
//  outside the visitor's tab, and silence. A quality switch, a decode error, a
//  transport retry, a retry budget running out and a permanent demotion to
//  software decode all left no durable trace whatsoever.
//
//  ONE ROW PER EVENT, DELIBERATELY. Each id below is both a probe (the durable
//  two-year count: "how often does this happen at all") and the name of the
//  span the same emission opens (the fourteen-day drilldown: "show me one").
//  `analytics/streamEvents.ts` is the single call site for every one of them
//  and carries the taxonomy — what each means, when it fires, what it carries
//  and how it is sampled. Declaring them here and emitting them there is the
//  same split every other area file makes.
//
//  GRADES ARE ALL `auto`, AND THAT IS THE POINT. Not one of these is a person
//  doing something — they are the machine reporting on itself, which is
//  exactly the class the intent ladder calls `auto`. A stream event graded
//  `act` would be a lie about who caused it.
//
//  See catalogue/types.ts for what each field means and catalogue/index.ts for
//  the invariant that makes a zero meaningful.
// ============================================================================

import type { MetricSpec, ProbeSpec } from './types.ts';

/** Every id below is emitted through `emitStreamEvent`, so they share one
 *  owner. That is not a shortcut around the call-site gate — it is the gate
 *  working: the taxonomy IS the call site, and an id that fell out of the
 *  table would fail here rather than quietly reading zero forever. */
const OWNER = 'src/analytics/streamEvents.ts';

export const STREAM_EVENT_PROBES = {
  // ---- quality (ABR) -------------------------------------------------------
  // THE HIGHEST-VALUE ONE. Until now the tier and CRF appeared only folded
  // into the 5-second clientlog `stats` line, which is a sample: two samples
  // either side of a switch prove a switch happened SOMEWHERE in five seconds,
  // and a switch that happened and reverted between two samples is invisible.
  // This fires ON the change, from the KIND_PARAMS record that carries it.
  'stream.quality.switch': {
    area: 'stream',
    owner: OWNER,
    what: 'the server moved a live viewer to a different encoder tier/CRF — the event the 5-second stats sample structurally could not report',
    grades: ['auto'],
  },
  // ---- decode --------------------------------------------------------------
  'stream.decode.error': {
    area: 'stream',
    owner: OWNER,
    what: 'a WebCodecs configure/decode call failed — previously caught, console-logged and therefore invisible to installErrorCapture and to reportError',
    grades: ['auto'],
  },
  'stream.decode.rebuild': {
    area: 'stream',
    owner: OWNER,
    what: 'a silently wedged decoder (AUs arriving, no output, no error callback) was torn down and rebuilt',
    grades: ['auto'],
  },
  'stream.decode.softwareLatched': {
    area: 'stream',
    owner: OWNER,
    what: 'this page gave up on the hardware decoder for the rest of its life — a visitor now paying CPU for every frame, and until now leaving no trace at all',
    grades: ['auto'],
  },
  // ---- keyframes -----------------------------------------------------------
  // There is NO client-side keyframe REQUEST channel to instrument: the daemon
  // forces an IDR on subscribe and runs a keyframe heartbeat, so the browser
  // never asks. What the browser HAS is two ways of waiting for one, and those
  // are the events.
  'stream.keyframe.gap': {
    area: 'stream',
    owner: OWNER,
    what: 'a frame_id gap armed the decode gate, so the picture is frozen on the last clean frame until the next key AU heals the reference chain',
    grades: ['auto'],
  },
  'stream.keyframe.timeout': {
    area: 'stream',
    owner: OWNER,
    what: 'the transport was up and the first-frame budget expired without a keyframe, so the ladder spent an attempt on a station that answered but did not paint',
    grades: ['auto'],
  },
  // ---- audio ---------------------------------------------------------------
  // The whole audio path had zero telemetry. An exhibit that is silent for
  // every visitor and an exhibit nobody has turned the sound on for look
  // identical from outside the tab.
  'stream.audio.start': {
    area: 'stream',
    owner: OWNER,
    what: 'the first Opus sample actually reached the speakers on this session — the only proof a station has audible sound',
    grades: ['auto'],
  },
  'stream.audio.blocked': {
    area: 'stream',
    owner: OWNER,
    what: 'the AudioContext refused to resume (autoplay policy or a dead context), so this visitor is watching a silent machine and nothing told us',
    grades: ['auto'],
  },
  // ---- transport -----------------------------------------------------------
  // transport.ts had zero emissions across all nine of its sites, and the
  // connect ladder's only number (`station.open.attemptCount`) is committed
  // ONLY on a painted frame — so a session that retried and never painted
  // contributed nothing anywhere.
  'stream.transport.retry': {
    area: 'stream',
    owner: OWNER,
    what: 'the connect ladder spent one attempt, with the reason it spent it — reported per retry, unlike the attempt COUNT which only exists for sessions that eventually painted',
    grades: ['auto'],
  },
  'stream.transport.exhausted': {
    area: 'stream',
    owner: OWNER,
    what: 'the retry budget ran out: this session is over and the visitor is looking at a poster or an error, the terminal outcome retryBudget.ts had no way to report',
    grades: ['auto'],
  },
  'stream.transport.closed': {
    area: 'stream',
    owner: OWNER,
    what: 'the WebTransport session ended, and whether it was a clean server-side close, a QUIC error or a connect that never opened',
    grades: ['auto'],
  },
  // ---- client-internal stalls ---------------------------------------------
  'stream.stall.detected': {
    area: 'stream',
    owner: OWNER,
    what: 'the client frame watchdog latched — no decoded frame for well past the station heartbeat while the transport still looked healthy',
    grades: ['auto'],
  },
  'stream.sink.paused': {
    area: 'stream',
    owner: OWNER,
    what: 'the <video> sink is paused on a visible page, so nothing is CONSUMING a healthy stream — the fault videoResume.ts exists for, previously clientlog-only',
    grades: ['auto'],
  },
  // ---- coming back ---------------------------------------------------------
  'stream.resume.decision': {
    area: 'stream',
    owner: OWNER,
    what: 'the resume policy judged a backgrounded session live or dead, and on what evidence — the branch that decides whether a return costs a rebuild',
    grades: ['auto'],
  },
} as const satisfies Record<string, ProbeSpec>;

export const STREAM_EVENT_METRICS = {
  // THE FLAP DETECTOR. A LOW value here is the finding, not a high one: tiers
  // that change every few seconds are the fleet-wide ABR flap this lab has
  // already been bitten by once, and a switch COUNT cannot distinguish it from
  // a link that legitimately degraded twice in an hour.
  //
  // Bitrate is deliberately NOT the bucketed metric. This plane has three
  // ladders (ms, count, pct) and none of them can carry kbps without lying
  // about its own resolution; the exact `targetKbps` rides as a span
  // ATTRIBUTE, where it is a number and not a bucket, and as Instana's
  // `customMetric` on the same event.
  'stream.quality.sinceLastSwitchMs': {
    area: 'stream',
    owner: OWNER,
    what: 'a LOW value means the encoder is thrashing between tiers rather than settling — the flap signature, which a switch count alone cannot separate from honest adaptation',
    scale: 'ms',
  },
  'stream.decode.errorRun': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means decode failures are arriving consecutively with no output between them, which is a dead decoder rather than a bad frame',
    scale: 'count',
  },
  'stream.keyframe.gapFrames': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means whole runs of frames are missing at once, so the link is dropping bursts rather than the occasional packet',
    scale: 'count',
  },
  'stream.keyframe.waitMs': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means visitors wait out the full first-frame budget on stations that connect but do not paint, so the budget is being spent rather than used',
    scale: 'ms',
  },
  'stream.audio.toFirstSampleMs': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means sound arrives long after the picture, so a visitor has already decided the exhibit is silent before it speaks',
    scale: 'ms',
  },
  'stream.transport.retryAttempt': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means retries are landing deep in the budget rather than succeeding on the first re-try, so the backoff ladder is absorbing a fault instead of riding out a blip',
    scale: 'count',
  },
  'stream.stall.sinceLastPaintMs': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means the watchdog only notices long after the picture stopped, so the client-side threshold is set above what a visitor will sit through',
    scale: 'ms',
  },
  'stream.resume.probeMs': {
    area: 'stream',
    owner: OWNER,
    what: 'a high value means the liveness probe that gates every resume is itself slow, so the black area after coming back is partly this decision rather than the rebuild it triggers',
    scale: 'ms',
  },
} as const satisfies Record<string, MetricSpec>;
