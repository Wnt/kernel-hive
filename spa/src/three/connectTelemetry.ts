// ============================================================================
//  connectTelemetry — everything the analytics plane wants to know about one
//  attempt to open a station, in one object.
//  ---------------------------------------------------------------------------
//  WHY THIS IS ITS OWN MODULE. `useStreamhostSession` is the file where the
//  connect ladder lives, and it sits ON the repo's 600-line hard cap
//  (scripts/check-file-size.mjs) with several instrumentation streams still to
//  land. Threading each one through it directly means every new measurement is
//  a negotiation with the size budget, settled by deleting comments from code
//  that has nothing to do with the measurement. So the session hook calls a
//  handful of named things and this file carries the reasoning behind all of
//  them.
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
//
//  ---- AND THE THING THAT IS NOT HERE BECAUSE IT CANNOT BE ------------------
//  There is no cold-vs-warm split on this connect, and its absence is a
//  deliberate finding rather than an omission.
//
//  A station that was idle-paused and had to be resumed is a different wait
//  from one already streaming, and merging the two does make the p95 partly a
//  statement about how often the fleet is asleep. But the browser cannot tell
//  them apart, and nothing available to it is an honest proxy:
//
//    * the signaling document carries no run state — `cert.rs` writes tile,
//      host, port, cert hash, wire version and encoder params, and an
//      idle-paused station's response is byte-identical to a running one's;
//    * the bit genuinely exists as `was_paused` in the daemon
//      (streamhost/src/idle.rs, `Freezer::session_started`), but it is computed
//      AFTER the transport is accepted and goes only to the journal, so it
//      could not reach the signaling fetch even in principle;
//    * `coldBoot` in the registry is station METADATA — "this machine has no
//      vmstate to resume into" — constant on every connect, and labelling a
//      runtime wait with it would be a category error;
//    * retry count is dominated by network, cert rotation and decoder
//      fallback, so calling a slow connect "cold" would be inventing the
//      attribution the number is supposed to supply.
//
//  Under this plane's own boundary rule — if the daemon could answer it, this
//  plane does not ask it — the split is the DAEMON's to publish, not the tab's
//  to guess. The minimal honest fix is one additive KIND_PARAMS subtype pushed
//  once at session start carrying `was_paused`; until that exists the split
//  stays unmeasured and is SAID to be unmeasured, which is the difference
//  between a gap and a lie.
//
//  Note also that cold/warm is already spoken for in this subtree:
//  `MAX_COLD_ATTEMPTS` and `markWarm()` mean "has this client painted a frame
//  yet", nothing to do with guest pause state. A metric reusing those words
//  would be permanently confusing whichever way it was defined.
// ============================================================================

import { accumulator, beginFlow, startTiming, type Timing } from '../analytics';
import type { FlowHandle } from '../analytics/flows';

/** One attempt-sequence's telemetry. Every method is safe to call in any order
 *  and any number of times; the underlying handles settle exactly once. */
export interface ConnectTelemetry {
  /** The transport is being brought up. Reported once — later calls are
   *  ignored by the funnel, which is what makes a retry ladder count as one
   *  attempt rather than as N. */
  transport(): void;
  /** The ladder is spending another attempt. Counted, never reported as its
   *  own sample: see `station.open.attemptCount`. */
  retry(): void;
  /** A frame was actually painted. This, not `phase === 'live'`, is the end of
   *  both the funnel and the clock: the phase has gone live on a session that
   *  stayed a spinner, so the phase is the gallery's opinion and the painted
   *  frame is the visitor's. */
  firstFrame(): void;
  /** A TRUSTED human input edge reached the guest. Only the first one matters;
   *  the rest are the visitor using the machine, which is a different subject. */
  firstInput(): void;
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
  // ONE sample per attempt-sequence, not one per retry. A `recordMetric` in the
  // retry path would produce a distribution of ones that says only that retries
  // happen; the total is what says what the connect COST.
  //
  // Counted as ATTEMPTS, not retries, so the count ladder's floor does not
  // swallow the answer: the `count` scale's smallest bucket is 1, so a
  // zero-retry connect and a one-retry connect would both land in `1` and the
  // metric's most common case would be unreadable. Attempt 1 is the connect
  // itself, so a clean connect is 1 and the first retry is genuinely 2.
  const attempts = accumulator('station.open.attemptCount');
  attempts.add(1);
  // Started only once a frame exists — "time to touch" is measured from the
  // moment there is something worth touching, not from the click that asked
  // for it. Waiting for a spinner is `toFirstFrameMs`; this is what happens
  // after the machine is already working.
  let inputMs: Timing | null = null;
  let settled = false;

  /** Release every handle exactly once. The timing set is bounded, so a path
   *  that forgets one silently stops the plane measuring anything. */
  const release = () => {
    settled = true;
    openMs.abandon();
    inputMs?.abandon();
    inputMs = null;
  };

  return {
    transport() {
      flow.step('transport');
    },
    retry() {
      attempts.add(1);
    },
    firstFrame() {
      if (settled) return;
      flow.step('firstFrame');
      flow.ok();
      openMs.stop();
      attempts.commit();
      if (!inputMs) inputMs = startTiming('station.open.toFirstInputMs');
    },
    firstInput() {
      const t = inputMs;
      inputMs = null;
      t?.stop();
    },
    gaveUp(hadPicture: boolean) {
      flow.fail(hadPicture ? 'lost' : 'nolive');
      release();
    },
    abandoned() {
      flow.close();
      release();
    },
  };
}
