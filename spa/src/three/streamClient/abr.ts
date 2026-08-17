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
import { T_STATS, FRAME_STALL_MS, MIN_SESSION_STALE_MS, MAX_SESSION_STALE_MS } from './constants';

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

  const totalFrames = this.receivedInterval + this.missedInterval;
  this.lossPct = totalFrames > 0 ? (this.missedInterval * 100) / totalFrames : 0;
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
  const stalledNow =
    !!this.wt && !this.disposed && this.lastDecodeOutAt > 0
    && (now - this.lastDecodeOutAt > FRAME_STALL_MS);
  if (stalledNow && !this.frameStalled) {
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
  if (stalledNow && this.lastAuAt > this.lastDecodeOutAt
      && now - this.lastStallRebuildAt > 4000) {
    this.lastStallRebuildAt = now;
    logClientEvent('stall', 'decoder rebuild (silent stall: AUs arriving, no output)');
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
  if (stalledNow && pageVisible && now - this.lastDecodeOutAt >= staleMs) {
    this.dropStaleSession(
      'stream-stalled',
      `no decoded frame for ${Math.round(now - this.lastDecodeOutAt)}ms (heartbeat ${keyframeMs}ms)`,
    );
    return;
  }

  // ---- banner state machine (Section 2.6) ----
  this.updateBanner(now);

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
