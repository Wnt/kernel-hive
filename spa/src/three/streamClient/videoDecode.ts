// ============================================================================
//  streamClient/videoDecode — the WebCodecs H.264 decode feed for StreamClient.
//  ---------------------------------------------------------------------------
//  These are `this`-typed implementation functions for StreamClient methods,
//  split out of the god-module purely for file size; the bodies are lifted
//  verbatim and operate on the SAME StreamClient instance (no state moved).
//
//  DECODE MODE (Firefox fix): the client configures the decoder in the WebCodecs
//  "avc" mode — an avcC `description` synthesized from the in-band SPS/PPS of
//  each key AU, plus Annex-B→AVCC converted chunks. Chrome and Safari support the
//  same mode, so it is ONE code path; the old bare-annexb configure (broken in
//  Firefox, Bugzilla 1918769) remains only as a fallback when SPS/PPS extraction
//  fails.
//
//  KIND_PARAMS (server→client encoder params + HUD stats) is decoded here too
//  because it feeds desiredCodec / encParams / serverStats — the decode state.
// ============================================================================

import type { StreamClient } from '../streamClient';
import type { ByteReader } from './byteReader';
import type { StreamEncoderParams, StreamServerStats } from './types';
import {
  extractSpsPps,
  annexbToAvcc,
  buildAvcC,
  codecFromSps,
  bytesEqual,
} from '../annexb';
import { logClientEvent, isVerboseDebug } from '../clientDebug';
import { codecStringFor } from './format';
import { isStaleAu } from './auGate';
import { DECODER_FAIL_THRESHOLD, IS_FIREFOX } from './constants';
import { isSoftwareDecodeLatched, latchSoftwareDecode } from './softwareDecodeLatch';
import { bytesToHex, noteDecodeSubmit, noteDecoded, noteFrameMark, noteReceived } from './frameTrace';

// ---- server→client encoder params + HUD stats (KIND_PARAMS) --------------
export async function handleParamsStreamImpl(this: StreamClient, br: ByteReader) {
  const subtype = await br.readU8();
  if (subtype == null) return;
  if (subtype === 1) {
    // encoder-params: 16 fixed bytes (18 total incl KIND+subtype), then an
    // OPTIONAL 4-byte native-geometry tail (native_width u16 LE, native_height
    // u16 LE) a newer server appends so the HUD can flag a REAL tier-3 downscale.
    // An old server omits it → readBytes(4) returns null at stream end and the
    // native fields stay undefined (the overlay then just shows decoded dims).
    const b = await br.readBytes(16);
    if (!b) return;
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const enc: StreamEncoderParams = {
      tier: dv.getUint8(0),
      width: dv.getUint16(1, true),
      height: dv.getUint16(3, true),
      targetKbps: dv.getUint32(5, true),
      crf: dv.getUint8(9),
      fpsCap: dv.getUint8(10),
      keyframeMs: dv.getUint16(11, true),
      profileIdc: dv.getUint8(13),
      levelIdc: dv.getUint8(14),
      presetEnum: dv.getUint8(15),
    };
    const nb = await br.readBytes(4);
    if (nb) {
      const ndv = new DataView(nb.buffer, nb.byteOffset, nb.byteLength);
      enc.nativeWidth = ndv.getUint16(0, true);
      enc.nativeHeight = ndv.getUint16(2, true);
    }
    this.encParams = enc;
    // Keep the decoder codec in sync with the live encoder (Section 3.2). A tier
    // change is an ffmpeg restart that emits a fresh SPS+PPS+IDR, so we defer the
    // reconfigure to the next keyframe (feedVideoAU) — never mid-GOP.
    const codec = codecStringFor(enc.profileIdc, enc.levelIdc);
    if (codec) this.desiredCodec = codec;
  } else if (subtype === 2) {
    // server-stats for HUD (28-byte core; 26 remaining here), then an OPTIONAL
    // 4-byte L-1 skip-counter tail (cumulative per-session egress skips, u32 LE).
    // An old server omits it → readBytes(4) returns null at stream end and
    // skippedFrames stays undefined (loss accounting then behaves as before).
    const b = await br.readBytes(26);
    if (!b) return;
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const stats: StreamServerStats = {
      tier: dv.getUint8(0),
      targetKbps: dv.getUint32(1, true),
      measuredSendKbps: dv.getUint32(5, true),
      pathRttUs: dv.getUint32(9, true),
      pathCwnd: dv.getUint32(13, true),
      pathLost: dv.getUint32(17, true),
      latencyScore: dv.getUint8(21),
      lossScore: dv.getUint8(22),
      bandwidthScore: dv.getUint8(23),
      overallScore: dv.getUint8(24),
      qp: dv.getUint8(25),
    };
    const sb = await br.readBytes(4);
    if (sb) {
      const sdv = new DataView(sb.buffer, sb.byteOffset, sb.byteLength);
      stats.skippedFrames = sdv.getUint32(0, true);
    }
    this.serverStats = stats;
  } else if (subtype === 3) {
    // Return-path frame-trace mark (docs/lab/TRACE-CONTEXT.md §3.2/§8.1,
    // `transport/egress.rs::spawn_frame_mark`): frame_id (u32 LE) + trace-id
    // (16 BE) + span-id (8 BE) naming which AU answered a sampled input
    // edge. `frameTrace.ts` matches it against this tab's own receive/
    // decode/paint timestamps for that frame_id, in whichever order the two
    // independent uni-streams happen to arrive.
    const b = await br.readBytes(28);
    if (!b) return;
    const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    const frameId = dv.getUint32(0, true);
    const traceId = bytesToHex(b.subarray(4, 20));
    const spanId = bytesToHex(b.subarray(20, 28));
    noteFrameMark(frameId, traceId, spanId, this.stationId);
  } else {
    await br.readToEnd();
  }
}

/** hardwareAcceleration for configure(): Firefox always 'no-preference'
 *  (its probe/prefer-hardware answers are untrustworthy); elsewhere nudge
 *  'prefer-hardware' only when the probe confirmed a HW decoder. */
export function pickAccelImpl(this: StreamClient): 'prefer-hardware' | 'no-preference' {
  if (IS_FIREFOX) return 'no-preference';
  // A page-lifetime demotion outranks this client's own (always-fresh) probe:
  // a reconnect must not walk back into the hardware decoder that an earlier
  // client already proved silent. See softwareDecodeLatch.
  if (isSoftwareDecodeLatched()) return 'no-preference';
  return this.hwDecodeOk === true && !this.hwFellBack ? 'prefer-hardware' : 'no-preference';
}

/** Record a configure/decode failure: count it, surface it (console max 1/s,
 *  metrics, telemetry) and latch 'decoder-failed' after 3 consecutive
 *  failures with zero output frames (the output callback resets the run). */
export function noteDecodeFailureImpl(this: StreamClient, msg: string) {
  this.decodeErrors++;
  this.lastDecodeError = msg;
  this.consecutiveDecodeFails++;
  if (this.consecutiveDecodeFails >= DECODER_FAIL_THRESHOLD) this.decoderFailed = true;
  // console + telemetry throttled to max 1/s (counters still track every
  // failure; the emitted detail carries the consecutive count).
  const now = performance.now();
  if (now - this.lastDecodeErrorLogAt >= 1000) {
    this.lastDecodeErrorLogAt = now;
    console.error(`[streamhost] decoder error (${this.consecutiveDecodeFails} consecutive): ${msg}`);
    logClientEvent('decoder-error', `${msg} (consecutive=${this.consecutiveDecodeFails})`);
  }
}

export function setupVideoDecoderImpl(this: StreamClient) {
  this.videoDecoder = new VideoDecoder({
    output: (frame) => {
      this.stats.framesDecoded++;
      // A real output frame ends any configure/decode failure run.
      this.consecutiveDecodeFails = 0;
      this.decoderFailed = false;
      this.stallRebuildsWithoutOutput = 0; // real output ends the rebuild run
      const now = performance.now();
      // decode-time diff (Section 2.2): match this frame to its submit time.
      const ts = frame.timestamp;
      const submit = this.submitTimes.get(ts);
      if (submit != null) {
        this.decodeTimeSum += (now - submit);
        this.decodeCountInterval++;
        this.submitTimes.delete(ts);
      }
      this.lastDecodeOutAt = now;
      this.frozen = false; // a painted frame clears the freeze latch
      const w = frame.displayWidth, h = frame.displayHeight;
      if (w && h && (w !== this.stats.guestW || h !== this.stats.guestH)) {
        this.stats.guestW = w; this.stats.guestH = h;
        try { this.cfg.onResolution?.(w, h); } catch { /* noop */ }
      }
      // fps
      this.fCount++;
      if (this.fT === 0) this.fT = now;
      if (now - this.fT >= 1000) {
        this.stats.fps = +(this.fCount * 1000 / (now - this.fT)).toFixed(1);
        this.fCount = 0; this.fT = now;
      }
      // Hand the frame to the sink; it takes ownership and closes it. Timed
      // for return-path tracing: the sink's `drawImage` (the direct-canvas
      // paint path, `useStreamhostSession.ts`) runs SYNCHRONOUSLY inside this
      // call, so wrapping it is a real paint measurement, not a guess — no
      // separate hook into the paint sink was needed.
      try { this.cfg.onVideoFrame(frame); } catch { try { frame.close(); } catch { /* noop */ } }
      noteDecoded(ts, now, performance.now());
    },
    error: (e) => {
      this.stats.lastError = `decode: ${String(e)}`;
      // No longer swallowed: count + surface every decoder error (metrics,
      // HUD, telemetry; console throttled to 1/s in noteDecodeFailure).
      this.noteDecodeFailure(String(e));
      // A VideoDecoder error is FATAL for the instance (state -> closed), so
      // ALWAYS tear it down and rebuild at the next keyframe — a one-shot
      // latch here left the station black forever after a second error (e.g. a
      // mid-GOP join against an old server relaying broken references).
      // Chrome >= 150 also reports an impossible hardwareAcceleration
      // preference HERE (async), not as a configure() throw — the first
      // error therefore additionally drops the 'prefer-hardware' nudge.
      if (!this.hwFellBack) {
        this.hwFellBack = true;
        this.hwDecodeOk = false;
        // Page-lifetime too: the replacement client a reconnect builds probes
        // 'prefer-hardware' from scratch and would repeat this same failure.
        latchSoftwareDecode();
      }
      try { this.videoDecoder?.close(); } catch { /* already closed */ }
      this.videoDecoder = null;
      this.videoReady = false; // next key AU reconfigures via maybeConfigureForKey
      // Force a FULL reconfigure at the next key even if SPS/PPS bytes match.
      this.cachedSps = null;
      this.cachedPps = null;
    },
  });
}

/**
 * Key-AU (re)configuration — the single decoder-config decision point:
 *   - extract SPS/PPS from the Annex-B key AU; on success configure the
 *     "avc" mode (codec string from the REAL SPS bytes + avcC description),
 *     reconfiguring ONLY when the SPS/PPS bytes changed (tier restarts emit
 *     a fresh SPS+PPS+IDR → exactly one reconfigure);
 *   - on extraction failure, configure bare annexb exactly as before (and
 *     feed unconverted AUs), logging decoder-config with why.
 */
export function maybeConfigureForKeyImpl(this: StreamClient, au: Uint8Array) {
  const needDecoder = !this.videoReady || !this.videoDecoder;
  const ps = this.avcConfigBroken ? { sps: null, pps: null } : extractSpsPps(au);
  if (ps.sps && ps.pps) {
    const changed =
      !bytesEqual(ps.sps, this.cachedSps) || !bytesEqual(ps.pps, this.cachedPps);
    if (!needDecoder && !changed && this.decodePath === 'avc') return;
    // About to (re)configure. NEVER configure() a LIVE instance in place:
    // Firefox's decoder can silently stop emitting output after an in-place
    // reconfigure with new dimensions — no error callback, canvas frozen
    // forever (win95 GTA DOS-box mode switch, 640x400 -> 640x480 SPS change,
    // 2026-07-14). A fresh instance reconfigures deterministically on every
    // engine, and parameter-set changes are rare (tier restarts / guest mode
    // switches), so the rebuild cost is irrelevant.
    if (this.videoDecoder) {
      try { this.videoDecoder.close(); } catch { /* noop */ }
      this.videoDecoder = null;
    }
    this.setupVideoDecoder();
    this.configureAvc(ps.sps, ps.pps);
  } else {
    if (isVerboseDebug() && !this.avcConfigBroken) {
      console.warn('[streamhost] key AU without extractable SPS/PPS — annexb fallback');
    }
    if (needDecoder) {
      this.setupVideoDecoder();
      this.configureAnnexb(
        this.desiredCodec,
        this.avcConfigBroken ? 'avc configure failed earlier' : 'no SPS/PPS extracted from key AU',
      );
    } else if (this.decodePath === 'annexb' && this.desiredCodec !== this.activeCodec) {
      // Legacy annexb-path codec switch (KIND_PARAMS desiredCodec at keyframe).
      this.configureAnnexb(this.desiredCodec, 'codec change on annexb path');
    }
  }
}

/** Configure the spec "avc" mode: avcC description + AVCC chunks. */
export function configureAvcImpl(this: StreamClient, sps: Uint8Array, pps: Uint8Array) {
  if (!this.videoDecoder) return;
  // Codec string derived from the REAL SPS (profile/constraint/level bytes) —
  // replaces the hardcoded-constraint codecStringFor for the configure call.
  const codec = codecFromSps(sps);
  const desc = buildAvcC(sps, pps);
  const accel = this.pickAccel();
  try {
    this.videoDecoder.configure({
      codec,
      description: desc,
      optimizeForLatency: true,
      hardwareAcceleration: accel,
    });
    this.activeCodec = codec;
    this.cachedSps = sps;
    this.cachedPps = pps;
    this.decodePath = 'avc';
    this.videoReady = true;
    this.logDecoderConfig(`avc path, codec=${codec}, desc=${desc.length}B, hw=${accel}`);
    if (isVerboseDebug()) console.info(`[streamhost] decoder-config avc codec=${codec} desc=${desc.length}B hw=${accel}`);
  } catch (e) {
    // avc-mode configure THREW (sync) — latch it off and fall back to annexb.
    this.avcConfigBroken = true;
    this.cachedSps = null;
    this.cachedPps = null;
    this.stats.lastError = `vconfig: ${String(e)}`;
    this.noteDecodeFailure(`vconfig(avc): ${String(e)}`);
    this.configureAnnexb(this.desiredCodec, `avc configure threw: ${String(e)}`);
  }
}

/** Bare-annexb configure — the pre-Firefox-fix behavior, now fallback-only. */
export function configureAnnexbImpl(this: StreamClient, codec: string, why: string) {
  if (!this.videoDecoder) return;
  const accel = this.pickAccel();
  try {
    this.videoDecoder.configure({
      codec,
      optimizeForLatency: true,
      hardwareAcceleration: accel,
    });
    this.activeCodec = codec;
    this.decodePath = 'annexb';
    this.videoReady = true;
    this.logDecoderConfig(`annexb fallback: ${why} (codec=${codec}, hw=${accel})`);
  } catch (e) {
    this.stats.lastError = `vconfig: ${String(e)}`;
    this.noteDecodeFailure(`vconfig(annexb): ${String(e)}`);
    // Last-resort fall back to baseline so we at least try to paint something.
    if (codec !== 'avc1.42e01e') {
      try {
        this.videoDecoder.configure({
          codec: 'avc1.42e01e', optimizeForLatency: true, hardwareAcceleration: 'no-preference',
        });
        this.activeCodec = 'avc1.42e01e';
        this.decodePath = 'annexb';
        this.videoReady = true;
        this.logDecoderConfig(`annexb fallback: ${why}; baseline last-resort`);
        return;
      } catch { /* nothing more to do */ }
    }
    // Nothing configured — drop the instance so the next key AU retries clean.
    try { this.videoDecoder?.close(); } catch { /* noop */ }
    this.videoDecoder = null;
    this.videoReady = false;
  }
}

export function feedVideoAUImpl(this: StreamClient, bytes: Uint8Array) {
  if (this.disposed || bytes.length < 9) return;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const frameId = dv.getUint32(0, true);
  const isKey = dv.getUint8(4) === 1;
  // Return-path tracing (frameTrace.ts): the wire arrival of every AU, cheap
  // and unconditional — no span here, just a bounded timestamp the mark
  // (if one ever names this frame_id) will later pair with a decode+paint
  // pair to emit real spans from.
  noteReceived(frameId, performance.now());
  // OUT-OF-ORDER / STALE-AU GUARD: per-AU uni streams complete in retransmit
  // order, not frame_id order — a delayed delta arriving behind the newest
  // frame would decode against the wrong reference. Keys always pass (an IDR
  // also self-heals any frame_id discontinuity after an encoder reopen).
  if (isStaleAu(this.lastFrameId, frameId, isKey)) return;
  const ts = dv.getUint32(5, true);
  const au = bytes.subarray(9);
  this.stats.framesRecv++;
  if (isKey) this.keyAUsSeen++;

  // ---- ABR instrumentation: bytes, loss (frame_id gaps), arrival time ----
  this.recvBytesInterval += bytes.length;
  this.lastAuAt = performance.now();
  if (this.lastFrameId >= 0) {
    const gap = (frameId - this.lastFrameId - 1) | 0;
    if (gap > 0 && gap < 0x40000000) {
      // Missed frame_ids = frames lost in transit (congestion). Feeds both the
      // per-interval loss rate and the cumulative drop counter (WebCodecs exposes
      // no drop count of its own, so frame_id gaps are our authoritative source).
      this.missedInterval += gap;
      this.framesDropped += gap;
      // GAP → KEYFRAME GATE: the AUs we never received are this stream's
      // reference frames — arm the gate so deltas are dropped until the next
      // IDR (freeze the last clean picture instead of painting corruption).
      this.auGate.noteGap();
    }
  }
  this.lastFrameId = frameId;
  this.lastDecodedFrameId = frameId;
  this.receivedInterval++;

  // Key AUs own ALL decoder (re)configuration: SPS/PPS extraction → avc mode
  // (description + AVCC), reconfigured only on parameter-set byte changes;
  // annexb fallback when extraction fails. Deltas before the decoder is
  // ready are dropped (same as before — we must start on a key).
  if (isKey) this.maybeConfigureForKey(au);
  if (!this.videoReady || !this.videoDecoder) return;

  // Gap→keyframe gate: keys always decode (and clear the gate); deltas are
  // dropped while a frame_id gap awaits its healing IDR.
  if (!this.auGate.admit(isKey)) return;

  // avc mode feeds AVCC (u32-BE length-prefixed NALs, SPS/PPS stripped —
  // they live in the description); annexb fallback feeds the raw AU.
  let data: Uint8Array = au;
  if (this.decodePath === 'avc') {
    data = annexbToAvcc(au);
    if (data.length === 0) {
      // No feedable NAL (e.g. malformed AU / SPS+PPS-only) — skip the chunk.
      if (isVerboseDebug()) console.warn(`[streamhost] AU ${frameId} converted to 0 NALs — skipped`);
      return;
    }
  }
  // Record submit time so the output callback can diff decode latency.
  const submitAt = performance.now();
  this.submitTimes.set(ts, submitAt);
  if (this.submitTimes.size > 240) {
    // bound the map — drop the oldest inserted key
    const first = this.submitTimes.keys().next().value;
    if (first !== undefined) this.submitTimes.delete(first);
  }
  // Return-path tracing: `ts` is the only join key the output callback below
  // gets back from WebCodecs, so record frameId against it now.
  noteDecodeSubmit(frameId, ts, submitAt);
  try {
    this.videoDecoder.decode(new EncodedVideoChunk({
      type: isKey ? 'key' : 'delta',
      timestamp: ts,
      data,
    }));
  } catch (e) {
    this.stats.lastError = `decode: ${String(e)}`;
    this.noteDecodeFailure(`decode(sync): ${String(e)}`);
  }
}
