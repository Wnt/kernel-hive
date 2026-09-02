// ============================================================================
//  streamClient/scoring — the pure math behind the client-local `el` scorer
//  (Section 2.3): the EWMA smoother and the per-interval raw score computation.
//  No streamhost state — lifted verbatim from tickStats so it can be unit-tested
//  directly. The stateful EWMA accumulation + banner state machine stay in abr.ts.
// ============================================================================

import { clamp0100 } from './format';

/** EWMA: ewma(prev,new,m) = prev*(m-1)/m + new/m. */
export function ewma(prev: number, next: number, m: number): number {
  return prev * (m - 1) / m + next / m;
}

/**
 * May the `el` scorer run at all yet?
 *
 * A client that is still negotiating has no RTT sample and no frames, and the
 * scorer's "unknown → worst" defaults then say the WORST possible thing:
 * `rttMs` falls back to 250, `latRaw` scores 0, `overall` is the min of the
 * three, and after the 2 s dwell the banner reads "Spotty connection" about a
 * session that has never had a connection to be spotty. Measured 2026-09-02:
 * reactos, whose WebTransport handshake never completed at all, showed
 * "Spotty connection" at +6.0 s interleaved with "Reconnecting to tile…
 * (attempt N)". Score nothing until there is something to score.
 */
export function scorerReady({ hasRtt, framesSeen }: { hasRtt: boolean; framesSeen: boolean }): boolean {
  return hasRtt && framesSeen;
}

export interface RawScoreInputs {
  /** last RTT sample in ms, already defaulted (unknown → 250, the worst). */
  rttMs: number;
  /** loss % over the just-closed interval. */
  lossPct: number;
  /** a freeze episode occurred in this interval. */
  freeze: boolean;
  /** frame_ids missed in this interval. */
  missed: number;
  /** videoDecoder.decodeQueueSize snapshot. */
  decodeQueue: number;
}

export interface RawScores {
  latRaw: number;
  lossRaw: number;
  bwRaw: number;
  overallRaw: number;
}

/**
 * Compute the un-smoothed per-interval latency / loss / bandwidth / overall
 * scores. Mirrors the exact arithmetic the scorer ran inline in tickStats:
 *   - latency: linear from RTT (250ms → 0, 0ms → ~104 clamped to 100).
 *   - loss: 100 - lossPct, zeroed by the GFN PLI+loss rule (freeze WITH loss).
 *   - bandwidth: 100, penalised as the decode queue backs up / freezes appear.
 *   - overall: the min of the three.
 */
export function rawScores({ rttMs, lossPct, freeze, missed, decodeQueue }: RawScoreInputs): RawScores {
  const latRaw = clamp0100((250 - rttMs) / 2.4);
  let lossRaw = clamp0100(100 - lossPct);
  // GFN PLI+loss rule: a freeze WITH any loss zeroes the loss score.
  if (freeze && missed > 0) lossRaw = 0;
  // Bandwidth relative to the CURRENT tier cap: 100 when the decoder keeps up
  // (queue ≤ 1, no freeze); drops as the queue backs up / freezes appear = starved.
  let bwRaw = 100;
  if (decodeQueue > 1) bwRaw -= (decodeQueue - 1) * 25;
  if (freeze) bwRaw -= 40;
  bwRaw = clamp0100(bwRaw);
  const overallRaw = Math.min(latRaw, lossRaw, bwRaw);
  return { latRaw, lossRaw, bwRaw, overallRaw };
}
