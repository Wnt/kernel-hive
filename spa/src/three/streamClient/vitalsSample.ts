// ============================================================================
//  streamClient/vitalsSample — one tick of StreamClient state -> one vitals row
//  ---------------------------------------------------------------------------
//  SPLIT FROM `vitals.ts` so that the sink (queue, flush, retry, wire format)
//  knows nothing about StreamClient and can be tested under plain Node, and so
//  that this — the part that will change every time a vital is added — is a
//  file with one job and no I/O in it. The same seam `telemetry.ts` uses to
//  keep `formatStatsLine` free of the client.
//
//  THE KEYS ARE THE STORE'S COLUMN NAMES, verbatim from
//  `scripts/serve/vitals_schema.py` CATALOGUE. Not camel-cased on the way out
//  and re-cased on the way in: one name from the field that measures it to the
//  axis that plots it. A key the server has not deployed yet is ignored there,
//  so this file may lead a deploy; a key it knows and this file stops sending
//  simply goes NULL, which reads correctly as "not measured".
// ============================================================================

import type { StreamClient } from '../streamClient';
import { recordVitals, skewMs } from './vitals';
import type { VitalSample } from './vitals';

/** Add `k` only when `n` is a real number. A vital that is absent must be
 *  ABSENT, never zero: the store stores NULL for it and every consumer knows
 *  the difference between "we measured 0 fps" and "we could not measure fps". */
function put(v: VitalSample, k: string, n: number | null | undefined): void {
  if (typeof n === 'number' && Number.isFinite(n)) v[k] = n;
}

/**
 * Take one sample off the ABR tick and queue it.
 *
 * Called from `abr.ts` at `STATS_LOG_MS` (5 s), beside the existing stats log
 * line, and reads ONLY state that tick has already computed — there is no new
 * measurement in this file, which is why adding the whole lane costs the hot
 * path nothing measurable.
 */
export function sampleVitals(c: StreamClient, now: number, decodeQueue: number): void {
  const d = c.telemetry.snapshot(now);
  const enc = c.encParams;
  const srv = c.serverStats;
  const v: VitalSample = {};

  // ---- video, the client's own view -------------------------------------
  put(v, 'fps', c.decodeFps);
  // PAINT fps is not decode fps, and shipping both is the point: frames can
  // decode and never reach the screen (a hidden tab, a throttled compositor),
  // and the pair is what tells those apart from a stream that is not arriving.
  put(v, 'paint_fps', c.stats.fps);
  put(v, 'recv_kbps', c.recvKbps);
  put(v, 'decode_ms', c.decodeMs);
  put(v, 'decode_queue', decodeQueue);
  put(v, 'loss_pct', c.lossPct);
  put(v, 'window_loss_pct', d.windowLossPct);
  put(v, 'frames_dropped', c.framesDropped);
  put(v, 'freeze_count', c.freezeCount);
  put(v, 'decode_errors', c.decodeErrors);
  put(v, 'session_rebuilds', c.sessionRebuilds);
  put(v, 'key_aus', c.keyAUsSeen);

  // ---- what the encoder was asked for ------------------------------------
  put(v, 'tier', enc?.tier);
  put(v, 'crf', enc?.crf);
  put(v, 'width', enc?.width);
  put(v, 'height', enc?.height);
  put(v, 'fps_cap', enc?.fpsCap);
  // The PEAK CAP, not a target (types.ts is explicit about that), and it is
  // here so `recv_kbps` has a ceiling to be read against. A stream at 1.8 Mbit
  // is healthy under a 2 Mbit cap and starved under a 6 Mbit one.
  put(v, 'target_kbps', enc?.targetKbps);

  // ---- transport ---------------------------------------------------------
  // Every figure here comes from the application-level ping and from frame_id
  // gaps. `WebTransport.getStats()` is undefined in the browser this gallery
  // serves (measured — transportFacts.ts:19-27), so there is no datagram-loss
  // or congestion counter to read and none is invented.
  put(v, 'rtt_ms', c.lastRtt);
  put(v, 'rtt_floor_ms', d.rttFloorMs);
  put(v, 'rtt_excess_ms', d.rttExcessMs);
  put(v, 'rtt_peak_ms', d.rttPeakMs);
  put(v, 'rtt_breach_ticks', d.rttBreachTicks);

  // ---- the SERVER's view of the same stream, relayed --------------------
  // Free: `serverStats` is KIND_PARAMS subtype 2, which the daemon has been
  // sending at 1 Hz per session since it was written and which nothing but the
  // ABR skip-credit and the Ctrl+N overlay has ever read. Putting it beside
  // the client's own numbers is what settles "is it the network or the box"
  // without a repro — send_kbps high while recv_kbps is low is the network,
  // both low is the box.
  put(v, 'send_kbps', srv?.measuredSendKbps);
  put(v, 'path_rtt_ms', srv ? srv.pathRttUs / 1000 : undefined);
  put(v, 'skipped_frames', srv?.skippedFrames);
  put(v, 'score_overall', srv?.overallScore);

  // ---- audio -------------------------------------------------------------
  const a = c.audioPlayer.vitals();
  if (a) {
    put(v, 'audio_running', a.running);
    put(v, 'audio_lead_ms', a.leadMs);
    put(v, 'audio_underruns', a.underruns);
    put(v, 'audio_gaps', a.gaps);
    put(v, 'audio_frames', a.frames);
    // ---- A/V sync, and the honest account of what it measures ------------
    // Both operands are the SERVER's capture clock: the Opus header's ts_us
    // and the AU header's ts are written by the same capture side, which is
    // what makes this a subtraction rather than a clock-sync problem. What it
    // measures is skew through OUR PIPELINE — how far apart in capture time
    // the audio we have just scheduled and the video we have just decoded are.
    //
    // TWO IMPRECISIONS, stated rather than buried. The video operand is the
    // last DECODED frame, not the last COMPOSITED one, so this carries up to
    // one frame interval (~33 ms at 30 fps) of error. And the audio operand is
    // the last packet SCHEDULED, which plays `audio_lead_ms` in the future, so
    // the lead is subtracted to bring both to "what the visitor is
    // experiencing now". A reading of ±40 ms is inside the noise those two
    // together allow; a reading of 500 ms is real.
    if (a.tsUs != null && c.lastVideoTsUs != null) {
      put(v, 'av_skew_ms', skewMs(a.tsUs, c.lastVideoTsUs) - a.leadMs);
    }
  }

  recordVitals(v);
}
