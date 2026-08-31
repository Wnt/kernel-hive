// ============================================================================
//  resumeTelemetry — coming BACK to a station, which is not the same code as
//  arriving at one.
//  ---------------------------------------------------------------------------
//  WHY THIS IS A FIRST-CLASS FLOW rather than a footnote on `station.connect`.
//  The resume path shares almost nothing with the initial connect: it is
//  `resumeSignals.ts` (four different events, because in an installed PWA a
//  return from another app is not one event), `resumePolicy.ts` (is the session
//  dead, or merely quiet?), `sessionResume.ts` (the grace window and the parked
//  -error recovery probe) and `videoResume.ts` (the paused <video> that pulls
//  nothing and makes a healthy transport look broken). Every one of those
//  exists because of a field failure, and NONE of them is visible in today's
//  numbers: a resume that takes eight seconds and a resume that takes eighty
//  milliseconds are the same single `station.connect` funnel entry, or no entry
//  at all.
//
//  ---- THE ONE HONEST USE OF `countsHiddenTime` ---------------------------
//  `session.resume.awayMs` is measured on the WALL clock, and it is the only
//  metric in the catalogue that may be. metrics.ts stops the clock while the
//  tab is hidden because a connect that took four minutes with three of them
//  backgrounded is not a four-minute wait — the number is supposed to describe
//  a person's PATIENCE, and hidden time is not patience. Away-time inverts
//  that exactly: the quantity IS the absence. Measuring it in visible time
//  would return zero every single time, which is not a distribution but a
//  tautology.
//
//  It earns the exception because it drives a real decision that nothing else
//  can answer. The daemon pauses an idle guest after a grace window and holds
//  a wake lease for 90 s (streamhost/src/idle.rs); how long visitors actually
//  stay away is what says whether those windows are set anywhere near right.
//  Nowhere else in this group is that flag appropriate, and it must not spread.
//
//  ---- WHY THE OUTCOME IS TWO METRICS, NOT ONE ----------------------------
//  A resume ends one of two ways and they are different engineering problems.
//  Either the session was still there and the picture simply had to start
//  pulling again (`videoResume`: a play() call, tens of milliseconds), or it
//  was gone and the whole transport had to be rebuilt (`sessionResume`: a
//  grace window, a signaling fetch, a WebTransport handshake, a keyframe).
//  Fused into one number the distribution is bimodal, its p95 describes only
//  how often the second case happens, and no action follows from it. Split,
//  the pair says plainly whether the fix is "keep sessions alive longer while
//  backgrounded" or "make the rebuild faster" — and because the two are
//  disjoint by construction, one resume is one sample in exactly one of them.
// ============================================================================

import { beginFlow, startTiming, type Timing } from '../analytics';
import type { FlowHandle } from '../analytics/flows';
import type { Attrs } from '../analytics/trace';

/** Telemetry for one station session's foreground/background cycles. */
export interface ResumeTelemetry {
  /** The document went away. Starts the away clock and nothing else — a visit
   *  that never comes back is not a resume and reports no resume. */
  hidden(): void;
  /** A resume signal fired and the document is on screen again. Opens the flow
   *  and starts the to-live clock. Idempotent: `resumeSignals` deliberately
   *  fires up to four times for one app switch, and every listener there is a
   *  HINT rather than a fact, so this must tolerate the same. */
  woke(): void;
  /** The session was dead and the transport is being rebuilt from scratch
   *  (sessionResume / the parked-error recovery probe). There is deliberately
   *  no matching `stillLive()`: the live case is what a resume IS unless
   *  something says otherwise, and a method the wiring would have to remember
   *  to call is a method that silently mislabels every path that forgets. */
  reconnecting(): void;
  /** A frame painted. Ends the resume: this, and not a state flag, is the
   *  moment the visitor has a moving picture back. */
  painted(): void;
  /** Teardown. Reports nothing for a resume still in flight — the visitor who
   *  left again mid-resume is the funnel's drop-off, and a duration for a
   *  resume that never completed would describe a wait nobody finished. */
  end(): void;
}

export function resumeTelemetry(stationAttrs?: Attrs): ResumeTelemetry {
  let awayMs: Timing | null = null;
  let flow: FlowHandle | null = null;
  // BOTH outcome clocks run from the same instant, and exactly one is stopped.
  // A metric id is fixed when its timing starts, so the alternative — deciding
  // the id at the end — would mean starting the reconnect clock at the moment
  // the answer is already known and recording a zero. Two handles for one
  // episode, one sample out.
  let toLive: Timing | null = null;
  let toLiveReconnect: Timing | null = null;
  /** Which of the two disjoint outcome metrics this resume belongs to.
   *  `null` until the session has been judged. */
  let route: 'live' | 'reconnect' | null = null;
  let ended = false;

  /** Drop everything in flight without recording. The timing set is bounded,
   *  so a path that forgets one silently stops the plane measuring anything. */
  const release = () => {
    toLive?.abandon();
    toLiveReconnect?.abandon();
    toLive = null;
    toLiveReconnect = null;
    flow?.close();
    flow = null;
    route = null;
  };

  return {
    hidden() {
      if (ended || awayMs) return;
      awayMs = startTiming('session.resume.awayMs', stationAttrs);
    },
    woke() {
      if (ended) return;
      // Nothing was away: a `focus` or `pageshow` on a tab that never left is
      // a hint firing spuriously, not a resume, and counting it would fill the
      // distribution with zero-length absences.
      const away = awayMs;
      if (!away) return;
      awayMs = null;
      away.stop();
      if (flow) return; // already resuming; the extra hint is harmless
      flow = beginFlow('session.resume');
      if (stationAttrs) flow.tag(stationAttrs);
      toLive = startTiming('session.resume.toLiveMs', stationAttrs);
      toLiveReconnect = startTiming('session.resume.reconnectToLiveMs', stationAttrs);
    },
    reconnecting() {
      if (ended || !flow) return;
      // A resume that starts live and then loses the session is a RECONNECT:
      // the visitor's wait includes the rebuild either way, and the cheaper
      // label would understate it. One-way, so it cannot flip back.
      route = 'reconnect';
      flow.step('transport');
    },
    painted() {
      if (ended || !flow) return;
      const t = toLive;
      const tr = toLiveReconnect;
      const f = flow;
      const r = route;
      toLive = null;
      toLiveReconnect = null;
      flow = null;
      route = null;
      f.step('firstFrame');
      f.ok();
      // Disjoint by construction: exactly one is stopped, the other abandoned.
      // A resume judged neither way — the picture came back before anything
      // decided — is the live case, which is what it was.
      if (r === 'reconnect') {
        tr?.stop();
        t?.abandon();
      } else {
        t?.stop();
        tr?.abandon();
      }
    },
    end() {
      if (ended) return;
      ended = true;
      // An absence still open at teardown records nothing: the visitor never
      // came back, so there is no resume to describe.
      awayMs?.abandon();
      awayMs = null;
      release();
    },
  };
}
