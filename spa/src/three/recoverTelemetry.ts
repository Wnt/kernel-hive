// ============================================================================
//  recoverTelemetry — a stall from the VISITOR's point of view.
//  ---------------------------------------------------------------------------
//  The delicate one. This repo measures the stream three ways already — the
//  Cmd/Ctrl+N overlay, clientlog's 5-second stats line, and `abr.rs` in the
//  daemon — and a fourth number that disagreed with all three would be worse
//  than having none. So the boundary from docs/ANALYTICS.md is enforced here
//  literally: loss, RTT, tier and bitrate are NOT measured in this file, and
//  must not be added to it. The daemon owns all four and is better placed to
//  say them.
//
//  What is left is the part no encoder can see: how long a person sat looking
//  at a picture that had stopped moving, and whether they gave up. Both are
//  derived from the PAINT side via `stallWatch` — frames that reached the
//  glass — never from the encoder's account of what it sent, because the whole
//  failure mode worth catching is the one where those two disagree.
//
//  ONE EPISODE, ONE SAMPLE, ACROSS A PAIR. A freeze ends exactly one of two
//  ways: the picture moves again, or the visitor stops looking. Those are the
//  two metrics, and they are disjoint by construction — each stall episode
//  stops one timing and abandons the other, so a single freeze can never
//  appear in both distributions and can never be missing from both. That is
//  what makes them comparable: `stallMs` is the population that waited it out,
//  `abandonedAfterMs` is the population that did not, and counting them at the
//  same granularity (per episode, both) is what lets the two be read together.
// ============================================================================

import { beginFlow, startTiming, type Timing } from '../analytics';
import type { FlowHandle } from '../analytics/flows';
import type { Attrs } from '../analytics/trace';
import { StallWatch } from './stallWatch';

/** Telemetry for one station session's freezes. Safe to call in any order. */
export interface RecoverTelemetry {
  /** The connect ladder is spending an attempt. Only meaningful while a freeze
   *  is open, where it separates "the software noticed and tried" from "the
   *  picture stopped and nothing happened" — two very different findings that
   *  a single frozen-to-moving number would merge. */
  reconnecting(): void;
  /** The station's advertised keyframe heartbeat, as soon as it is known.
   *  Everything about the stall threshold derives from it — see stallWatch. */
  heartbeat(keyframeMs: number | null | undefined): void;
  /** A decoded frame reached the glass. Drives both the freeze detector and
   *  its recovery edge. */
  painted(): void;
  /** A TRUSTED human input edge went to the guest. Synthetic input must never
   *  reach here (see stallWatch): a type-in demo is not somebody waiting. */
  input(): void;
  /** Advance the detector without a paint — call from a timer. */
  poll(): void;
  /** The session is going away: navigation, teardown, or a station closed.
   *  A freeze open at this moment is an ABANDONMENT, which is the single most
   *  valuable observation this whole group makes — it is the only place in the
   *  system that records a visitor giving up. */
  end(): void;
}

/**
 * How often the detector is polled.
 *
 * A freeze is recognised on a poll, so this bounds how far past the threshold
 * a stall can be before it is noticed. Comfortably finer than the smallest
 * possible threshold (2 s) and cheap: it does no work but a subtraction unless
 * the picture has actually stopped.
 */
export const RECOVER_POLL_MS = 500;

/**
 * @param now Monotonic clock, injectable for tests. Production passes nothing
 *   and gets `performance.now()` — see `clock()` below for why not `Date.now`.
 *   Note this drives the DETECTOR only; the recorded durations come from the
 *   metrics lane's own clock, which is deliberately not something a call site
 *   can influence.
 */
export function recoverTelemetry(now: () => number = clock, stationAttrs?: Attrs): RecoverTelemetry {
  const watch = new StallWatch();
  // The two halves of one episode. Exactly one of them settles per freeze.
  let stallMs: Timing | null = null;
  let abandonMs: Timing | null = null;
  let flow: FlowHandle | null = null;
  let ended = false;

  const beginStall = () => {
    if (stallMs || abandonMs) return;
    // One flow per FREEZE, not per session: the question is how many freezes
    // came back, and a session-long flow could only ever answer it once.
    flow = beginFlow('stream.recover');
    if (stationAttrs) flow.tag(stationAttrs);
    stallMs = startTiming('stream.recover.stallMs', stationAttrs);
    abandonMs = startTiming('stream.recover.abandonedAfterMs', stationAttrs);
  };

  /** Settle the pair: record `keep`, drop the other. Never records both, and
   *  never records neither — an open pair left running would consume two slots
   *  of the bounded timing set for the life of the tab. */
  const settle = (keep: 'recovered' | 'abandoned') => {
    const s = stallMs;
    const a = abandonMs;
    const f = flow;
    stallMs = null;
    abandonMs = null;
    flow = null;
    if (keep === 'recovered') {
      s?.stop();
      a?.abandon();
      f?.step('moving');
      f?.ok();
    } else {
      a?.stop();
      s?.abandon();
      // `close()`, not `fail()`. A visitor who stops looking is already the
      // funnel's drop-off — `frozen` entered, `moving` never reached — and
      // reporting it as a fault as well would count every abandonment twice,
      // once as a lost visitor and once as a broken stream. The plane's
      // existing rule (analytics/flows.ts), applied to the one flow where the
      // drop-off is the whole point.
      f?.close();
    }
  };

  const apply = (at: number) => {
    const t = watch.tick(at);
    if (t === 'begin') beginStall();
    else if (t === 'end') settle('recovered');
  };

  return {
    heartbeat(keyframeMs) {
      watch.setHeartbeat(keyframeMs);
    },
    painted() {
      if (ended) return;
      const at = now();
      watch.painted(at);
      apply(at);
    },
    input() {
      if (ended) return;
      watch.input(now());
    },
    reconnecting() {
      if (ended) return;
      flow?.step('reconnecting');
    },
    poll() {
      if (ended) return;
      apply(now());
    },
    end() {
      if (ended) return;
      ended = true;
      // A freeze that was open when the visitor left is the abandonment. A
      // session with no freeze open records NOTHING here: a normal close is
      // not a zero-length stall, and inventing one would drag the whole
      // distribution to the floor.
      if (stallMs || abandonMs) settle('abandoned');
    },
  };
}

/** Monotonic, for the same reason metrics.ts insists on it: an NTP step or a
 *  laptop suspend mid-freeze would otherwise produce a negative or hour-long
 *  stall, and both survive bucketing to poison a durable distribution. */
function clock(): number {
  try {
    return typeof performance !== 'undefined' ? performance.now() : Date.now();
  } catch {
    return Date.now();
  }
}
