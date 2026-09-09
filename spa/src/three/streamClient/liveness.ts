// ============================================================================
//  streamClient/liveness — when is a tile actually GONE?
//  ---------------------------------------------------------------------------
//  The old rule was: three consecutive type-9 RTT pings time out ⇒ the link is
//  dead ⇒ tear the transport down and rebuild it. Two things made that fire on
//  a healthy 12 ms LAN (2026-09-02 dossier, operator tab 18:39:03 / 18:43:41):
//
//    * THE PING IS A DATAGRAM, on a path that is allowed to drop them. Video
//      rides reliable uni-streams; the echo does not. Three dropped datagrams
//      in a row is a busy uplink, not a dead station.
//    * A BLOCKED MAIN THREAD TIMES ITS OWN PINGS OUT. The 600 ms deadline is a
//      `setTimeout` racing a `read()` on the same starved event loop, so six
//      decoders on one laptop — or a daemon paused for a loadvm — manufacture
//      "timeouts" for echoes that actually came back in 12 ms. And because the
//      ABR loop fired a ping every 100 ms without waiting for the previous one,
//      "3 consecutive" could be reached ~800 ms into a single hiccup, not the
//      1.8 s the comment claimed.
//
//  The honest question is not "did this ping come back" but "is ANYTHING still
//  arriving from the server". Video AUs, audio, KIND_PARAMS and datagrams are
//  all proof of life and all cheaper to trust than an echo. So:
//
//    ok       — pings answering, or data still arriving.
//    suspect  — strikes reached but the server is still sending: SOFT state.
//               The banner may say 'spotty'; the transport is NOT rebuilt.
//    lost     — strikes reached AND nothing at all from the server for
//               SILENCE_MS. Only then do we drop the session.
//
//  Hard closes are untouched: a real transport error or a clean server finish
//  still tears down immediately through `transportDown` (transport.ts).
// ============================================================================

/** Consecutive unanswered liveness pings before the link is even suspect.
 *  Four rather than three at the daemon owner's request (2026-09-02): with the
 *  echo moved off the input path, a single missed echo next to fresh AUs is
 *  overwhelmingly a starved reader, and the strike count should say so. */
export const PING_STRIKES = 4;

/**
 * How long the server must be COMPLETELY silent — no uni-stream, no datagram —
 * before an unanswered-ping run is allowed to tear the transport down. Chosen
 * against the two legitimate stalls that used to trip the old rule: a daemon
 * paused for a loadvm/restore, and a main thread stalled by a tab full of
 * decoders. The frame watchdog (abr.ts FRAME_STALL_MS) still reports a frozen
 * picture long before this, and dropStaleSession('stream-stalled') still owns
 * the "connected but nothing decodes" case on its own, shorter clock.
 */
export const SILENCE_MS = 5000;

export type LivenessVerdict = 'ok' | 'suspect' | 'lost';

export interface LivenessInputs {
  /** consecutive liveness pings with no echo. */
  consecutiveTimeouts: number;
  /**
   * ms since ANY server traffic (uni-stream or datagram) last arrived, or null
   * when nothing has ever arrived — a session that never received a byte is
   * judged by the connect ladder's keyframe budget, not by this.
   */
  msSinceServerData: number | null;
}

export function livenessVerdict({ consecutiveTimeouts, msSinceServerData }: LivenessInputs): LivenessVerdict {
  if (consecutiveTimeouts < PING_STRIKES) return 'ok';
  if (msSinceServerData == null) return 'suspect';
  return msSinceServerData >= SILENCE_MS ? 'lost' : 'suspect';
}
