// ============================================================================
//  sessionTelemetry — the three station flows behind ONE handle.
//  ---------------------------------------------------------------------------
//  `useStreamhostSession` sits on the repo's 600-line hard cap
//  (scripts/check-file-size.mjs) and is where all three of these flows have
//  their real events: the connect ladder, the resume path and the paint stream
//  all pass through that one effect. Wiring three telemetry objects, a poll
//  timer and a set of resume listeners into it directly would cost it a hundred
//  lines and settle the size budget by deleting comments from code that has
//  nothing to do with measurement.
//
//  So this file does the assembly and the hook calls a handful of verbs. The
//  three underlying modules stay separate — and stay the catalogue `owner` of
//  their own ids — because each carries the reasoning for a different question:
//
//    connectTelemetry   how long the visitor waited, and what it cost
//    resumeTelemetry    coming back, which is entirely different code
//    recoverTelemetry   the picture stopped, and whether they gave up
//
//  Nothing here decides anything; it fans one event out to the objects that
//  care. Every rule about what is and is not measured lives in those files.
// ============================================================================

import { connectTelemetry } from './connectTelemetry';
import { recoverTelemetry, RECOVER_POLL_MS } from './recoverTelemetry';
import { resumeTelemetry } from './resumeTelemetry';
import { attachResumeSignals, isVisible } from './streamClient/resumeSignals';
import {
  KEYFRAME_WAIT_MS, RELIVE_KEYFRAME_WAIT_MS, RETRY_REASON_NO_KEYFRAME,
} from './streamClient/retryBudget';
import { logClientEvent } from './clientDebug';
import { emitStreamEvent } from '../analytics/streamEvents';
import type { Attrs } from '../analytics/trace';

/**
 * What the connect ladder knows about the attempt it just spent.
 *
 * The three EVENTS below all fall out of this one object, which is why the
 * hook reports it once rather than calling three telemetry verbs: `retry` is
 * the attempt itself; `keyframe.timeout` is the sub-case where the transport
 * came up and nothing painted; `transport.exhausted` is the budget running
 * out, which is the only terminal outcome `retryBudget.ts` can produce and
 * which — until now — left no trace anywhere at all.
 */
interface RetryDetail {
  /** Clamped to the budget by `consumeRetry`, so it never exceeds `limit`. */
  attempt: number;
  limit: number;
  /** A short stable token, never a message. */
  reason: string;
  /** Has this session ever painted? Decides which budget is in force. */
  live: boolean;
  /** Is this the reconnect after a golden restore (a different backoff)? */
  restore: boolean;
  /** The budget is spent: this session is over. */
  exhausted: boolean;
}

export interface SessionTelemetryDeps {
  /** The station's advertised keyframe heartbeat, read fresh each poll: it
   *  arrives on KIND_PARAMS after the transport is up, so it is null for the
   *  first moments of every session and must not be cached at construction. */
  getKeyframeMs(): number | null;
  /** Station-type grouping dimensions (analytics/stationAttrs.ts), stamped on
   *  every span/timing the three flows below open — so "how long do QEMU
   *  desktops take to reconnect" is one query, not a per-station-id average. */
  stationAttrs?: Attrs;
  /** Which CLIENT transport this session negotiated — webtransport, or the
   *  rare webrtc-fallback a WebCodecs-less browser takes. Not a station fact
   *  (it is decided by feature detection, not by the registry), so it is
   *  merged onto `stationAttrs` here rather than carried in it. */
  clientTransport?: string;
}

/** One station session's whole analytics surface. Every method is safe to call
 *  in any order and any number of times. */
export interface SessionTelemetry {
  /** The transport is being brought up (connect funnel). */
  transport(): void;
  /** The ladder is spending another attempt. Counts toward what the connect
   *  cost, and — if the picture is frozen right now — marks that the software
   *  actually reacted to the freeze rather than sitting through it. `detail`
   *  is what turns it into a reportable EVENT as well as a count. */
  retry(detail?: RetryDetail): void;
  /** The <video> sink is paused on a visible page: a healthy stream nobody is
   *  consuming. Also writes the /clientlog row the hook used to write inline,
   *  so the operator's existing debugging path is unchanged. */
  sinkPaused(endpoint: string, visible: boolean): void;
  /** The CURRENT attempt painted its first frame. */
  firstFrame(): void;
  /** Any decoded frame reached the glass. Called on every frame: it drives the
   *  freeze detector's recovery edge and ends a resume. */
  painted(): void;
  /** A TRUSTED human input edge reached the guest. Synthetic input (type-in
   *  demos, the win9x boot-modal auto-dismiss) must never reach this. */
  input(): void;
  /** The resume path decided the session was dead and is rebuilding it. */
  resumeReconnect(): void;
  /** The connect ladder gave up. */
  gaveUp(hadPicture: boolean): void;
  /** Session teardown. Settles every open handle — see each module for what a
   *  teardown reports (mostly nothing, deliberately) — and detaches the timer
   *  and listeners this module owns. */
  detach(): void;
}

export function sessionTelemetry(deps: SessionTelemetryDeps): SessionTelemetry {
  const attrs: Attrs = deps.clientTransport
    ? { ...deps.stationAttrs, 'kh.client.transport': deps.clientTransport }
    : (deps.stationAttrs ?? {});
  const connect = connectTelemetry(attrs);
  const resume = resumeTelemetry(attrs);
  const recover = recoverTelemetry(undefined, attrs);

  // The freeze detector needs a clock of its own: a stall is precisely the
  // absence of the paint events everything else here is driven by, so without
  // a timer a station that froze forever would never report a freeze.
  const poll = typeof window !== 'undefined'
    ? window.setInterval(() => {
      recover.heartbeat(deps.getKeyframeMs());
      recover.poll();
    }, RECOVER_POLL_MS)
    : 0;

  // The same event set `sessionResume` uses, and for the same reason: in an
  // installed PWA a return from another app is not one event, and getting the
  // set wrong is how a resume bug survives a fix. Every one is a HINT, so both
  // sides of this are idempotent.
  const onSignal = () => {
    if (isVisible()) resume.woke();
    else resume.hidden();
  };
  const detachSignals = attachResumeSignals(onSignal);
  // `attachResumeSignals` reports every hint including the one that HID the
  // page, so the hidden edge is covered by the same listener; nothing extra is
  // needed here beyond the initial state.
  if (typeof document !== 'undefined' && !isVisible()) resume.hidden();

  let detached = false;
  // One pause EPISODE is one event. The watchdog that detects it re-arms on a
  // timer for as long as the sink stays paused, and reporting that level would
  // either flood the plane or force a fault to be sampled — see the
  // `stream.sink.paused` row in analytics/streamEvents.ts.
  let sinkPausedReported = false;

  return {
    transport() {
      connect.transport();
    },
    retry(detail?: RetryDetail) {
      connect.retry();
      recover.reconnecting();
      if (!detail) return;
      // The keyframe WAIT expiring, reported before the retry it causes. The
      // browser has no keyframe REQUEST to instrument — the daemon forces an
      // IDR on subscribe and runs a heartbeat — so this is the only honest
      // keyframe event a tab can emit, and the budget it spent is knowable
      // from which ladder was in force.
      if (detail.reason === RETRY_REASON_NO_KEYFRAME) {
        const budgetMs = detail.live ? RELIVE_KEYFRAME_WAIT_MS : KEYFRAME_WAIT_MS;
        emitStreamEvent('stream.keyframe.timeout', {
          ...attrs,
          'kh.keyframe.budgetMs': budgetMs,
          'kh.stream.live': detail.live,
          'kh.stream.restore': detail.restore,
        }, budgetMs);
      }
      emitStreamEvent('stream.transport.retry', {
        ...attrs,
        'kh.retry.attempt': detail.attempt,
        'kh.retry.limit': detail.limit,
        'kh.retry.reason': detail.reason,
        'kh.stream.live': detail.live,
        'kh.stream.restore': detail.restore,
      }, detail.attempt);
      if (detail.exhausted) {
        emitStreamEvent('stream.transport.exhausted', {
          ...attrs,
          'kh.retry.attempt': detail.attempt,
          'kh.retry.limit': detail.limit,
          'kh.stream.live': detail.live,
        });
      }
    },
    sinkPaused(endpoint: string, visible: boolean) {
      // The /clientlog row is unchanged and unlatched: it is the operator's
      // debugging window and "still paused" every few seconds is exactly what
      // it is for. Only the analytics event is an edge.
      logClientEvent('sink-stalled', `paused sink, transport healthy — not retrying ep=${endpoint}`);
      if (sinkPausedReported) return;
      sinkPausedReported = true;
      emitStreamEvent('stream.sink.paused', { ...attrs, 'kh.sink.visible': visible });
    },
    firstFrame() {
      connect.firstFrame();
      // A painted frame is the end of the episode, so the next pause is a new
      // one and gets its own event.
      sinkPausedReported = false;
    },
    painted() {
      recover.painted();
      resume.painted();
    },
    input() {
      connect.firstInput();
      recover.input();
    },
    resumeReconnect() {
      resume.reconnecting();
    },
    gaveUp(hadPicture: boolean) {
      connect.gaveUp(hadPicture);
    },
    detach() {
      if (detached) return;
      detached = true;
      try { detachSignals(); } catch { /* noop */ }
      if (poll && typeof window !== 'undefined') window.clearInterval(poll);
      // Order matters only in that all three must run: each holds bounded
      // handles, and a leak silently stops the plane measuring anything.
      recover.end();
      resume.end();
      connect.abandoned();
    },
  };
}
