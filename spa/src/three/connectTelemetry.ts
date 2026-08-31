// ============================================================================
//  connectTelemetry — everything the analytics plane wants to know about one
//  attempt to open a station, in one object.
//  ---------------------------------------------------------------------------
//  WHY THIS IS ITS OWN MODULE. `useStreamhostSession` is the file where the
//  connect ladder lives, and it sits ON the repo's 600-line hard cap
//  (scripts/check-file-size.mjs) with several instrumentation streams still to
//  land. Threading each one through it directly means every new measurement is
//  a negotiation with the size budget, settled by deleting comments from code
//  that has nothing to do with the measurement. So the session hook calls four
//  named things and this file carries the reasoning behind all of them.
//
//  It also puts the two planes side by side, which is where the distinction is
//  easiest to keep straight:
//
//    the FLOW says how far an attempt got, and where it died.
//    the TIMING says how long the visitor waited to get there.
//
//  They are deliberately not fused (analytics/flows.ts): a flow's steps are
//  funnel edges, and making them clock edges too would mean neither could be
//  changed without moving the other.
//
//  WHAT IS DELIBERATELY NOT HERE: anything the daemon can already answer.
//  Encode, transport and decode timing have three better sources (the Ctrl+N
//  overlay, clientlog's 5-second stats line, the journal). This measures the
//  visitor — the wait between choosing a machine and seeing its desktop, which
//  starts before the stream exists and ends when a human's eyes are satisfied,
//  and which none of those three can see.
// ============================================================================

import { beginFlow, startTiming, type Timing } from '../analytics';
import type { FlowHandle } from '../analytics/flows';

/** One attempt-sequence's telemetry. Every method is safe to call in any order
 *  and any number of times; the underlying handles settle exactly once. */
export interface ConnectTelemetry {
  /** The transport is being brought up. Reported once — later calls are
   *  ignored by the funnel, which is what makes a retry ladder count as one
   *  attempt rather than as N. */
  transport(): void;
  /** A frame was actually painted. This, not `phase === 'live'`, is the end of
   *  both the funnel and the clock: the phase has gone live on a session that
   *  stayed a spinner, so the phase is the gallery's opinion and the painted
   *  frame is the visitor's. */
  firstFrame(): void;
  /** The ladder gave up. `hadPicture` separates a session that HAD a desktop
   *  and lost it from one that never got a frame — a different defect, which a
   *  single `fail` would merge. */
  gaveUp(hadPicture: boolean): void;
  /** The effect was torn down: the visitor navigated away mid-connect.
   *  Reports NOTHING. The abandonment is already visible as the funnel's
   *  drop-off, and calling it a failure would double-count it as a fault;
   *  recording a duration for it would put the whole retry ladder into a
   *  distribution that is supposed to describe successful waits. Not calling
   *  it is the real bug — both handle sets are bounded, and a leak silently
   *  stops the plane measuring anything. */
  abandoned(): void;
}

export function connectTelemetry(): ConnectTelemetry {
  const flow: FlowHandle = beginFlow('station.connect');
  const openMs: Timing = startTiming('station.open.toFirstFrameMs');
  return {
    transport() {
      flow.step('transport');
    },
    firstFrame() {
      flow.step('firstFrame');
      flow.ok();
      openMs.stop();
    },
    gaveUp(hadPicture: boolean) {
      flow.fail(hadPicture ? 'lost' : 'nolive');
      openMs.abandon();
    },
    abandoned() {
      flow.close();
      openMs.abandon();
    },
  };
}
