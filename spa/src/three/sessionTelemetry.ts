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

export interface SessionTelemetryDeps {
  /** The station's advertised keyframe heartbeat, read fresh each poll: it
   *  arrives on KIND_PARAMS after the transport is up, so it is null for the
   *  first moments of every session and must not be cached at construction. */
  getKeyframeMs(): number | null;
}

/** One station session's whole analytics surface. Every method is safe to call
 *  in any order and any number of times. */
export interface SessionTelemetry {
  /** The transport is being brought up (connect funnel). */
  transport(): void;
  /** The ladder is spending another attempt. Counts toward what the connect
   *  cost, and — if the picture is frozen right now — marks that the software
   *  actually reacted to the freeze rather than sitting through it. */
  retry(): void;
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
  const connect = connectTelemetry();
  const resume = resumeTelemetry();
  const recover = recoverTelemetry();

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

  return {
    transport() {
      connect.transport();
    },
    retry() {
      connect.retry();
      recover.reconnecting();
    },
    firstFrame() {
      connect.firstFrame();
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
