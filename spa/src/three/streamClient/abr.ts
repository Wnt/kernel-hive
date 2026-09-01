// ============================================================================
//  streamClient/abr — the client MEASURES + REPORTS; the server STEPS (Section 2).
//  ---------------------------------------------------------------------------
//  The ~100ms tick: roll the interval accumulators into rates, run the `el`
//  scorer (pure math in scoring.ts), the idle-frame-stall watchdog + silent
//  decoder self-heal, the banner state machine, and the T_STATS feedback
//  datagram. `this`-typed implementation functions for StreamClient methods,
//  split out of the god-module purely for file size; bodies are lifted verbatim
//  (only the extracted-scoring call sites differ) and operate on the SAME
//  StreamClient instance (no state moved).
// ============================================================================

import type { StreamClient } from '../streamClient';
import { logClientEvent } from '../clientDebug';
import { clampU16 } from './format';
import { ewma, rawScores } from './scoring';
import { bankServerSkips, spendSkipCredit } from './skipCredit';
import { formatStatsLine } from './telemetry';
import {
  T_STATS, FRAME_STALL_MS, FIRST_FRAME_GRACE_MS,
  MIN_SESSION_STALE_MS, MAX_SESSION_STALE_MS, MAX_SILENT_STALL_REBUILDS,
} from './constants';
import { latchSoftwareDecode } from './softwareDecodeLatch';
import { noteDecoderRebuild, noteStallLatched } from './analyticsEvents';

/** Rolling window the REPORTED loss percentage is measured over (ms). */
const LOSS_WINDOW_MS = 3000;
/**
 * Frames the window must hold before a loss percentage is reported at all.
 * Below this the ratio is dominated by its own quantisation — one missed frame
 * out of one is 100 %, not a congested link — so we report 0 instead.
 */
const LOSS_MIN_FRAMES = 10;
/**
 * Cadence of the periodic telemetry sample posted to the server-side rolling
 * log. 5 s matches clientDebug's normal batch flush, so a sample costs no extra
 * request; a session-hour is ~720 rows (~250 KB), which the sink's retention
 * comfortably holds.
 */
const STATS_LOG_MS = 5000;

/**
 * Roll the interval accumulators into rates, run the `el` scorer, update the
 * banner, and emit the T_STATS feedback datagram. Called on a ~100 ms cadence
 * by the controller (mirrors the RTT timer). Also fires a fresh RTT ping so the
 * next report has a current sample.
 */
export function tickStatsImpl(this: StreamClient): void {
  if (this.disposed || this.decoderUnsupportedReason) return;
  const now = performance.now();
  const elapsed = this.lastReportAt ? now - this.lastReportAt : 100;
  this.lastReportAt = now;

  // ---- rates over the just-closed interval ----
  if (elapsed > 0) {
    this.recvKbps = (this.recvBytesInterval * 8) / elapsed; // bytes*8/ms = kbps
    this.decodeFps = (this.decodeCountInterval * 1000) / elapsed;
  }
  this.recvBytesInterval = 0;
  if (this.decodeCountInterval > 0) this.decodeMs = this.decodeTimeSum / this.decodeCountInterval;
  this.decodeTimeSum = 0;
  this.decodeCountInterval = 0;

  // ---- L-1: discount server-known egress skips from this interval's gap misses ----
  // (see skipCredit.ts) — corrects lossPct, which drives BOTH the 'spotty' banner
  // AND the loss_pct the server ABR reads back, WITHOUT touching the decode gate
  // (auGate.noteGap): a skip really does drop references, so deltas still wait for
  // the next key; only the LOSS ACCOUNTING is corrected. No-op on a LAN (no skips).
  bankServerSkips(this, this.serverStats?.skippedFrames);
  this.missedInterval = spendSkipCredit(this, this.missedInterval);

  // ---- REPORTED loss: a rolling window with a MINIMUM DENOMINATOR ----
  // A percentage over one ~100 ms tick is meaningless on a low-fps station: at
  // 2 fps the denominator is 0-1 frames, so ONE dropped frame reports 100 %
  // loss and the server's 5 % downshift threshold (abr.rs DOWN_LOSS_PCT) trips
  // on statistical noise. That collapsed tru64 to the floor tier repeatedly on
  // a flawless LAN, and did the same on every low-fps 8-bit station.
  // We therefore report loss over the last LOSS_WINDOW_MS, and report ZERO
  // until the window has seen LOSS_MIN_FRAMES — an unmeasurable loss rate must
  // read as "no evidence of congestion", never as "total loss".
  this.lossWindow.push({
    at: now, recv: this.receivedInterval, missed: this.missedInterval,
  });
  while (this.lossWindow.length && this.lossWindow[0].at < now - LOSS_WINDOW_MS) {
    this.lossWindow.shift();
  }
  let wRecv = 0;
  let wMissed = 0;
  for (const w of this.lossWindow) { wRecv += w.recv; wMissed += w.missed; }
  const wTotal = wRecv + wMissed;
  this.lossPct = wTotal >= LOSS_MIN_FRAMES ? (wMissed * 100) / wTotal : 0;
  const missedThisInterval = this.missedInterval;
  const receivedThisInterval = this.receivedInterval;
  this.receivedInterval = 0;
  this.missedInterval = 0;

  // ---- diagnostic recorder (passive; never feeds the scorer or T_STATS) ----
  // Fed the RAW per-tick counters, not lossPct, so the overlay can show the
  // sample size behind every percentage — see telemetry.ts for why that matters.
  this.telemetry.tick({
    now,
    received: receivedThisInterval,
    missed: missedThisInterval,
    rttMs: this.lastRtt ?? null,
    framesDropped: this.framesDropped,
    freezeCount: this.freezeCount,
    tier: this.encParams?.tier ?? null,
  });

  // ---- freeze detection: no paint >250ms while AUs still arrive ----
  if (this.lastDecodeOutAt > 0 && (now - this.lastDecodeOutAt > 250)
      && this.lastAuAt > this.lastDecodeOutAt && !this.frozen) {
    this.freezeCount++;
    this.frozen = true;
    this.freezeInInterval = true;
  }
  const freezeThisInterval = this.freezeInInterval;

  // ---- decode queue snapshot ----
  const decodeQueue = this.videoDecoder ? (this.videoDecoder.decodeQueueSize || 0) : 0;

  // ---- el scorer (Section 2.3) — raw per-interval scores (see scoring.ts) ----
  const rttMs = this.lastRtt ?? 250; // unknown → worst
  const { latRaw, lossRaw, bwRaw, overallRaw } = rawScores({
    rttMs,
    lossPct: this.lossPct,
    freeze: freezeThisInterval,
    missed: missedThisInterval,
    decodeQueue,
  });

  if (!this.scoreInit) {
    this.scoreInit = true;
    this.sLatency = latRaw; this.sLoss = lossRaw; this.sBandwidth = bwRaw; this.sOverall = overallRaw;
  } else {
    // windows: latency/bandwidth m=16, loss m=8, overall m=4.
    this.sLatency = ewma(this.sLatency, latRaw, 16);
    this.sBandwidth = ewma(this.sBandwidth, bwRaw, 16);
    this.sLoss = ewma(this.sLoss, lossRaw, 8);
    this.sOverall = ewma(this.sOverall, overallRaw, 4);
  }

  // ---- idle-frame-stall watchdog (Item 4) ----
  //  DISTINCT from RTT-ping liveness: a wedged/throttled encoder can keep the
  //  QUIC link + type-9 pings perfectly healthy while zero frames decode. Latch
  //  when no frame has painted for > FRAME_STALL_MS and the transport is still
  //  open. DETECTOR ONLY — surfaced to the HUD/banner; it never triggers reconnect.
  //  The reference is the last DECODED frame — or, before this session has ever
  //  decoded one, transport-ready plus FIRST_FRAME_GRACE_MS. Measuring only from
  //  `lastDecodeOutAt` left a connected-but-never-decoding session (the shape a
  //  resume produces: every replacement client starts at zero, and a mobile
  //  app-switch routinely leaves the hardware decoder poisoned) invisible to
  //  BOTH the silent-stall rebuild and dropStaleSession below — the only
  //  recovery left was the hook's 12 s keyframe budget, i.e. 12 s of black.
  //  Gated on `warm`: only a RECONNECT to a station that has already painted may
  //  be judged on transport-ready. A cold first connect against a slow or idle
  //  station legitimately takes a while to produce frame #1 and keeps its
  //  existing behaviour (no stall chip, no drop) — the hook's 12 s cold
  //  keyframe budget stays that path's only deadline.
  const decodeRef = this.lastDecodeOutAt > 0
    ? this.lastDecodeOutAt
    : (this.warm && this.sessionReadyAt > 0 ? this.sessionReadyAt + FIRST_FRAME_GRACE_MS : 0);
  const stalledNow =
    !!this.wt && !this.disposed && decodeRef > 0
    && (now - decodeRef > FRAME_STALL_MS);
  if (stalledNow && !this.frameStalled) {
    // THE LATCH EDGE ONLY. A stall that lasts a minute is one event, not six
    // hundred ticks of one — the analytics plane counts episodes, and a level
    // reported per tick would make the count a function of how long the tab
    // stayed open rather than of how often stations freeze.
    noteStallLatched({
      thresholdMs: FRAME_STALL_MS,
      sinceLastPaintMs: now - decodeRef,
      hadDecodeError: !!this.lastDecodeError,
      stationId: this.stationId,
    });
    logClientEvent(
      'stall',
      `frame watchdog latched (> ${FRAME_STALL_MS}ms no decoded frame)${this.lastDecodeError ? `; last decoder error: ${this.lastDecodeError}` : ''}`,
    );
  }
  // SELF-HEAL (2026-07-14): a silently wedged decoder (output stops, NO error
  // callback — Firefox after a mid-stream geometry change) used to freeze the
  // station forever. If AUs are still ARRIVING while output is stalled, the
  // decoder instance itself is the problem: drop it so the next key AU
  // (keyframe heartbeat <= 2.5 s) rebuilds a fresh one via
  // maybeConfigureForKey. Rate-limited; never touches the transport.
  //  BOUNDED: a wedged decoder used to spin here every 5 s forever (measured: 10
  //  identical rebuilds over 65 s on a hidden tab, which dropStaleSession below
  //  cannot rescue because it correctly refuses to act while the page is
  //  hidden). Three attempts is more than enough to prove a rebuild is not the
  //  answer; after that stop burning them and leave the session to the stale
  //  drop the moment the page is visible again.
  if (stalledNow && this.lastAuAt > this.lastDecodeOutAt
      && this.stallRebuildsWithoutOutput < MAX_SILENT_STALL_REBUILDS
      && now - this.lastStallRebuildAt > 4000) {
    this.lastStallRebuildAt = now;
    this.stallRebuildsWithoutOutput++;
    // ESCALATE — a rebuild that re-creates the SAME configuration reproduces the
    // same silence, which is why this used to repeat until the session died
    // black. Output-with-no-error is overwhelmingly a hardware decoder left
    // poisoned by a GPU-context loss (mobile app-switch / tab discard), so the
    // rebuild also drops the 'prefer-hardware' nudge — the same demotion the
    // async decoder-error path performs, except this failure mode never
    // delivers an error to trigger it. The latch is process-wide (below) so the
    // replacement client a reconnect builds does not go straight back to the
    // hardware decoder that just failed to emit.
    latchSoftwareDecode();
    this.hwFellBack = true;
    this.hwDecodeOk = false;
    noteDecoderRebuild(this.stallRebuildsWithoutOutput, MAX_SILENT_STALL_REBUILDS, this.stationId);
    logClientEvent('stall', `decoder rebuild ${this.stallRebuildsWithoutOutput}/${MAX_SILENT_STALL_REBUILDS} (silent stall: AUs arriving, no output) — demoting to software decode`);
    try { this.videoDecoder?.close(); } catch { /* noop */ }
    this.videoDecoder = null;
    this.videoReady = false;
    this.cachedSps = null;
    this.cachedPps = null;
  }
  this.frameStalled = stalledNow;

  // A restore can leave Firefox's WebTransport object apparently open even
  // after the server-side session/encoder vanished. streamhost guarantees a
  // watched keyframe heartbeat, so prolonged absence of decoded output is a
  // terminal stale session. Reconnecting also replaces a decoder that failed
  // to recover from the lighter in-place rebuild above.
  const keyframeMs = this.encParams?.keyframeMs ?? this.signalVideo?.keyframeMs ?? 2500;
  const staleMs = Math.min(MAX_SESSION_STALE_MS, Math.max(MIN_SESSION_STALE_MS, keyframeMs * 2 + 3000));
  const pageVisible = typeof document === 'undefined' || document.visibilityState === 'visible';
  if (stalledNow && pageVisible && now - decodeRef >= staleMs) {
    this.dropStaleSession(
      'stream-stalled',
      this.lastDecodeOutAt > 0
        ? `no decoded frame for ${Math.round(now - this.lastDecodeOutAt)}ms (heartbeat ${keyframeMs}ms)`
        : `no first frame ${Math.round(now - this.sessionReadyAt)}ms after transport ready (heartbeat ${keyframeMs}ms)`,
    );
    return;
  }

  // ---- banner state machine (Section 2.6) ----
  this.updateBanner(now);

  // ---- periodic telemetry sample -> server-side rolling log ----
  // The overlay's diagnostics live ONLY in the browser, so a session that dies
  // takes its evidence with it: the 2026-08-17 win311 mid-game drop left no
  // client-side record at all. Sampling on a fixed cadence (and relying on
  // clientDebug's pagehide/visibilitychange keepalive flush) means the last
  // seconds before a drop are on disk even when the tab never comes back.
  if (now - this.lastStatsLogAt >= STATS_LOG_MS) {
    this.lastStatsLogAt = now;
    const enc = this.encParams;
    logClientEvent('stats', formatStatsLine(this.telemetry.snapshot(now), {
      tier: enc?.tier ?? null,
      crf: enc?.crf ?? null,
      w: enc?.width ?? null,
      h: enc?.height ?? null,
      fpsCap: enc?.fpsCap ?? null,
      recvKbps: this.recvKbps,
      decodeFps: this.decodeFps,
      decodeMs: this.decodeMs,
      decodeQueue,
      lossPct: this.lossPct,
      framesDropped: this.framesDropped,
      freezeCount: this.freezeCount,
      rttMs: this.lastRtt ?? null,
      banner: this.banner,
      decodePath: this.decodePath,
      decodeErrors: this.decodeErrors,
      sessionRebuilds: this.sessionRebuilds,
      stalled: this.frameStalled,
    }));
  }

  // ---- fire the feedback datagram + a fresh RTT ping ----
  this.sendStats(decodeQueue, missedThisInterval);
  this.freezeInInterval = false;
  void this.pingRtt(600).catch(() => { /* noop */ });
}

export function updateBannerImpl(this: StreamClient, now: number) {
  // Terminal browser capability failure: preserve the explicit fallback until
  // the user leaves. Generic scoring must not turn it back into "good".
  if (this.banner === 'decoder-unsupported') return;
  // Hard reconnecting: QUIC loss or 3 consecutive ping timeouts.
  if (this.transportDown || this.consecutivePingTimeouts >= 3) {
    this.banner = 'reconnecting';
    // Soft liveness loss (pings gone but the transport hasn't reported closed):
    // tag it 'ping-timeout' so the UI can distinguish it from a hard close. A
    // real transport close already set 'transport-down'/'server-finished' — don't
    // clobber that more-specific reason.
    if (this.consecutivePingTimeouts >= 3 && !this.transportDown) this.exitReason = 'ping-timeout';
    this.belowSince = 0; this.aboveSince = 0;
    return;
  }
  // Explicit local-decoder failure (≥3 consecutive configure/decode failures,
  // zero output frames): outranks spotty/good — the picture is down because of
  // the DECODER, not the network. Cleared by the first successfully decoded
  // frame (the output callback resets the latch).
  if (this.decoderFailed) {
    this.banner = 'decoder-failed';
    this.belowSince = 0; this.aboveSince = 0;
    return;
  }
  // Coming out of reconnecting/decoder-failed: fall back to good until the
  // EWMA proves spotty.
  if (this.banner === 'reconnecting' || this.banner === 'decoder-failed') this.banner = 'good';
  const o = this.sOverall;
  if (o < 60) { this.belowSince = this.belowSince || now; this.aboveSince = 0; }
  else if (o > 75) { this.aboveSince = this.aboveSince || now; this.belowSince = 0; }
  else { this.belowSince = 0; this.aboveSince = 0; }
  // Let the 2s dwell be the hysteresis (never threshold a raw sample).
  if (this.belowSince && now - this.belowSince >= 2000) this.banner = 'spotty';
  else if (this.aboveSince && now - this.aboveSince >= 2000) this.banner = 'good';
}

/** Emit the fixed 29-byte T_STATS feedback datagram (Section 3.1). */
export function sendStatsImpl(this: StreamClient, decodeQueue: number, _missed: number) {
  if (!this.dgWriter || this.disposed) return;
  const b = new Uint8Array(29);
  const dv = new DataView(b.buffer);
  dv.setUint8(0, T_STATS);
  dv.setUint32(1, (this.statSeq++ >>> 0), true);
  dv.setUint16(5, this.lastRtt == null ? 0xffff : clampU16(this.lastRtt), true);
  dv.setUint32(7, Math.max(0, Math.round(this.recvKbps)) >>> 0, true);   // recv_kbps @7 (server abr.rs:47)
  dv.setUint16(11, clampU16(this.decodeMs * 10), true);
  dv.setUint16(13, clampU16(this.decodeFps * 10), true);
  dv.setUint16(15, clampU16(decodeQueue), true);
  dv.setUint32(17, this.framesDropped >>> 0, true);
  dv.setUint16(21, clampU16(this.freezeCount), true);
  dv.setUint16(23, clampU16(this.lossPct * 10), true);
  dv.setUint32(25, this.lastDecodedFrameId >>> 0, true);
  this.writeDatagram(b);
}
