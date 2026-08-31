// ============================================================================
//  playTelemetry — one visitor's attempt to get a private clone and use it.
//  ---------------------------------------------------------------------------
//  THE QUESTION THIS EXISTS FOR is `poolSize`. Every walk-in station keeps a
//  warm pool of three clones (WALKIN-BRIEF), and there is currently no evidence
//  at all for or against that number: nobody measures how often a visitor meets
//  a full pool, and nobody measures how long the ones who do end up waiting.
//  Those are two different facts and both are needed — 30% queued for four
//  seconds is a healthy pool, 2% queued for four minutes is not, and either
//  number alone cannot tell you which you have. So the SPLIT is the design:
//
//    claimInstant / claimQueued   how often the pool was empty  (probes)
//    queueMs                      how long the queued ones sat  (metric)
//
//  A queue wait folded into one distribution with the instant claims would
//  make an exhausted pool and a healthy one produce the same picture, because
//  the instants are the overwhelming majority and they are all sub-second.
//
//  WHERE THIS STOPS AND THE STATION PLANE STARTS. `station.open.toFirstFrameMs`
//  already measures the wait from opening a machine to a painted frame, and
//  the stream's own latency has three better sources than either (the Ctrl+N
//  overlay, clientlog's stats line, the daemon's journal). What none of them
//  can see is the walk-in-only half: the broker's queue, and whether the clone
//  the pool spent was ever actually driven. That is what is measured here.
//
//  A RESET IS NOT A RETRY. "Reset — give me a fresh one" is the visitor asking
//  for a new clone and getting one: the feature working exactly as designed.
//  Counting it as a claim retry would report a working feature as friction, and
//  the retry number exists to find friction.
//
//  NO IDENTITY, AND NO CLONE ID. Which visitor took which machine is not
//  recorded and there is no column for it (scripts/serve/analytics.py). A clone
//  identity is per-visitor by construction, so it is exactly the kind of value
//  that would quietly turn a durable aggregate into a session log.
// ============================================================================

import { accumulator, beginFlow, reach, startTiming, type Timing } from '../analytics';
import type { FlowHandle } from '../analytics/flows';

/** One play attempt — one mount of the play surface for one station. */
export interface PlayTelemetry {
  /** A claim is going out. The first is the attempt; every later one is a retry
   *  UNLESS it is a reset (`reset: true`), which is the visitor being served,
   *  not the visitor trying again. */
  claiming(opts?: { reset?: boolean }): void;
  /** The broker answered with a queue position. Starts the queue clock on the
   *  FIRST such answer and leaves it running across retries: the visitor's wait
   *  is the whole wait, not the last leg of it. */
  queued(): void;
  /** The broker handed over a clone. */
  held(): void;
  /** The visitor put a deliberate input into the clone — the first moment the
   *  machine is demonstrably usable rather than merely painted. */
  drove(): void;
  /** The claim was refused because walk-in access is closed. A FENCE, not a
   *  fault: reported with its own reason so it is never read as a broker that
   *  could not produce a machine. */
  refused(): void;
  /** The claim failed for anything else. */
  failed(): void;
  /** The surface unmounted. Commits the retry count (including a zero — one
   *  press was enough, which is the outcome the pool is FOR) and drops every
   *  unfinished clock without a sample. */
  ended(): void;
}

export function playTelemetry(): PlayTelemetry {
  const flow: FlowHandle = beginFlow('walkin.play');
  const retries = accumulator('walkin.play.claimRetries');
  let queue: Timing | null = null;
  let toPlayable: Timing | null = null;
  let claims = 0;
  let settled = false;
  let done = false;

  return {
    claiming(opts) {
      claims += 1;
      if (claims > 1 && opts?.reset !== true) retries.add(1);
    },
    queued() {
      reach('walkin.play.claimQueued', 'auto');
      if (!queue) queue = startTiming('walkin.play.queueMs');
    },
    held() {
      // Instant means "no queue answer ever came back for this attempt", which
      // is the only definition the client can honestly make: it is the visitor's
      // experience of the pool, not the broker's opinion of its own occupancy.
      if (!queue) reach('walkin.play.claimInstant', 'auto');
      queue?.stop();
      if (settled) return;
      flow.step('held');
      // A reset gives a second clone before the first was ever driven; the
      // clock measures the CURRENT machine, so a running one is dropped rather
      // than stretched across two of them.
      toPlayable?.abandon();
      toPlayable = startTiming('walkin.play.toPlayableMs');
    },
    drove() {
      if (settled) return;
      settled = true;
      toPlayable?.stop();
      flow.step('driven');
      flow.ok();
    },
    refused() {
      if (settled) return;
      settled = true;
      queue?.abandon();
      toPlayable?.abandon();
      flow.fail('closed');
    },
    failed() {
      if (settled) return;
      settled = true;
      queue?.abandon();
      toPlayable?.abandon();
      flow.fail('claim');
    },
    ended() {
      if (done) return;
      done = true;
      queue?.abandon();
      toPlayable?.abandon();
      // The zero is the point: most visitors press Play once and get a machine,
      // and a distribution containing only the visitors who had to press twice
      // would report the pool as permanently exhausted.
      retries.commit();
      if (!settled) {
        settled = true;
        flow.close();
      }
    },
  };
}
