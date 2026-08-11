// ============================================================================
//  streamClient/transport — WebTransport(QUIC) session lifecycle for StreamClient:
//  connect + signaling capability probe, the incoming datagram/uni-stream read
//  loops, the Firefox poisoned-session watchdog + silent rebuild, per-stream
//  demux, and the soft stale-session drop.
//  ---------------------------------------------------------------------------
//  These are `this`-typed implementation functions for StreamClient methods,
//  split out of the god-module purely for file size; the bodies are lifted
//  verbatim and operate on the SAME StreamClient instance (no state moved).
// ============================================================================

import type { StreamClient } from '../streamClient';
import { ByteReader } from './byteReader';
import { fetchSignal } from './signal';
import { logClientEvent } from '../clientDebug';
import {
  INPUT_CLASSES,
  KIND_VIDEO,
  KIND_AUDIO,
  KIND_PARAMS,
  T_PING,
  IS_FIREFOX,
  FF_STALL_CHECK_MS,
  FF_STALL_QUIET_MS,
  FF_STALL_MAX_STREAMS,
  FF_STALL_MAX_REBUILDS,
} from './constants';

export async function connectImpl(this: StreamClient): Promise<void> {
  this.wtReady = false;
  this.transportDown = false;
  this.exitReason = null;
  this.consecutivePingTimeouts = 0;
  // Missing WebCodecs is terminal. Do not fetch signaling, open WebTransport,
  // arm watchdogs, or enter a retry loop: none of those can add a decoder.
  if (this.decoderUnsupportedReason) {
    this.emitNoVideo('capability');
    this.setState(false, this.stats.lastError);
    return;
  }
  // Fire the HW-decode capability probe early (result usually lands well
  // before the first keyframe needs a decoder). Any failure => software path.
  // Firefox: skip the probe entirely — its isConfigSupported answers are
  // untrustworthy (Bugzilla 1918769); pickAccel() forces 'no-preference'.
  if (IS_FIREFOX) this.hwDecodeOk = false;
  if (this.hwDecodeOk === null) {
    try {
      void VideoDecoder.isConfigSupported({
        codec: 'avc1.42e01e', optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware',
      }).then((s) => { if (this.hwDecodeOk === null) this.hwDecodeOk = !!s.supported; })
        .catch(() => { if (this.hwDecodeOk === null) this.hwDecodeOk = false; });
    } catch { this.hwDecodeOk = false; }
  }
  try {
    const sig = await fetchSignal(this.cfg.signalEndpoint);
    if (this.disposed) return;
    this.wireVersion = sig.wireVersion;
    this.signalVideo = sig.video ?? null;
    this.serverMaxUdpPayloadSize = sig.quic?.maxUdpPayloadSize ?? null;
    this.serverMtuDiscovery = sig.quic?.mtuDiscovery ?? null;
    // GO-LIVE FIX (Section 3.4): a High-profile Annex-B stream is silently
    // rejected by VideoDecoder.configure if we pin baseline avc1.42e01e. Use
    // the codec advertised in signaling.video.codec; fall back to baseline so
    // an old server / new client stays compatible.
    if (sig.video?.codec) { this.desiredCodec = sig.video.codec; }

    // Ask WebCodecs about the exact codec advertised by this station before
    // opening WebTransport. A definitive `supported:false` is terminal; a
    // rejected probe is inconclusive and falls through to configure(), whose
    // existing error path remains authoritative.
    if (sig.video?.codec && typeof VideoDecoder.isConfigSupported === 'function') {
      try {
        const support = await VideoDecoder.isConfigSupported({
          codec: sig.video.codec,
          ...(sig.video.width ? { codedWidth: sig.video.width } : {}),
          ...(sig.video.height ? { codedHeight: sig.video.height } : {}),
          optimizeForLatency: true,
          hardwareAcceleration: 'no-preference',
        });
        if (!support.supported) {
          this.decoderUnsupportedReason = 'codec-unsupported';
          this.banner = 'decoder-unsupported';
          this.stats.lastError = `the browser does not support the advertised video codec (${sig.video.codec})`;
          logClientEvent('decoder-unsupported', `codec=${sig.video.codec}`);
          this.emitNoVideo('capability');
          this.setState(false, this.stats.lastError);
          return;
        }
      } catch { /* inconclusive probe; configure() will provide the real result */ }
    }

    const wt = new WebTransport(sig.url, {
      serverCertificateHashes: [{ algorithm: 'sha-256', value: sig.certHash }],
      // Prefer latency over throughput for the client→server direction (spec
      // hint; UAs without the knob simply ignore it).
      congestionControl: 'low-latency',
    });
    this.wt = wt;
    // FIREFOX DELIVERY-RACE FIX (primary): attach the incoming uni-stream +
    // datagram readers BEFORE awaiting `ready`. Firefox 151 PERMANENTLY stops
    // surfacing server-opened incoming uni-streams to JS when any arrive
    // before the reader attaches — and our server primes the cached key AU
    // the instant it accepts the session, so it always races JS. Measured on
    // CT950 (10 sessions each): pre-ready attach 10/10 healthy; attach right
    // after `ready` 6/10; attach after the input-stream opens (the OLD order
    // here) 0/10. Chrome is indifferent to the order (3/3 healthy pre-ready).
    this.uniStreamsSeen = 0;
    this.lastUniStreamAt = 0;
    this.sessionReadyAt = performance.now();
    void this.readDatagrams(wt);
    void this.readIncomingStreams(wt);
    await wt.ready;
    if (this.disposed) { try { wt.close(); } catch { /* noop */ } return; }
    this.wtReady = true;
    this.sessionReadyAt = performance.now();
    this.armNoVideoTelemetry();
    // Belt-and-braces: if a session still comes up poisoned (the pre-ready
    // attach lost an unknown variant of the race), detect + rebuild it.
    if (IS_FIREFOX) this.armFfStallWatchdog(wt);

    this.setState(true, '-');
    logClientEvent('connect', `transport ok, codec=${sig.video?.codec ?? '(default)'}, wire=v${sig.wireVersion}, maxUdpPayload=${this.serverMaxUdpPayloadSize ?? 'unknown'}, mtud=${this.serverMtuDiscovery ?? 'unknown'}`);
    this.dgWriter = wt.datagrams.writable.getWriter() as WritableStreamDefaultWriter<Uint8Array>;
    // Expire move datagrams stuck in the send queue for >100 ms instead of
    // delivering stale pointer positions late (bufferbloat guard). Spec'd but
    // not implemented everywhere — never let the assignment throw.
    try { wt.datagrams.outgoingMaxAge = 100; } catch { /* unsupported UA */ }

    // Reliable input: PER-TYPE QUIC streams (HOL avoidance). Open ONE client-
    // opened unidirectional reliable stream per input CLASS, each led by its
    // 1-byte class tag, then reused for every length-prefixed record of that
    // class. Separate streams mean a lost/retransmitted mouse-button record can't
    // stall a keypress. The server's accept_uni router reads the tag and demuxes
    // to input::handle. Opened eagerly here (before any input can be sent) so the
    // synchronous send* methods just look up a ready writer.
    for (const tag of INPUT_CLASSES) {
      try {
        const s = await wt.createUnidirectionalStream();
        const w = s.getWriter() as WritableStreamDefaultWriter<Uint8Array>;
        await w.write(new Uint8Array([tag])); // class-tag prefix (once per stream)
        if (this.disposed) { try { void w.close().catch(() => { /* session gone */ }); } catch { /* noop */ } break; }
        this.inputWriters.set(tag, w);
      } catch (e) {
        this.stats.lastError = `input-stream ${tag}: ${String(e)}`;
      }
    }

    // (Datagram + incoming-stream readers were attached PRE-ready above —
    // the Firefox delivery-race fix; the input writers below can wait.)

    // Surface a clean teardown if the session closes underneath us. A RESOLVED
    // `closed` promise = the server closed cleanly (service stopped) → 'server-
    // finished'; a REJECTED one = a QUIC/transport error → 'transport-down'.
    // `this.wt === wt` guards a session we already replaced ourselves (poisoned-
    // session rebuild) from reporting its own teardown as a drop.
    void wt.closed
      .then(() => { if (!this.disposed && this.wt === wt && !this.transportDown) { this.wtReady = false; this.transportDown = true; this.exitReason = 'server-finished'; logClientEvent('wt-close', 'clean close (server-finished)'); this.setState(false, 'session closed'); } })
      .catch((e) => { if (!this.disposed && this.wt === wt && !this.transportDown) { this.wtReady = false; this.transportDown = true; this.exitReason = 'transport-down'; logClientEvent('wt-close', `transport error: ${String(e)}`); this.setState(false, `closed: ${String(e)}`); } });
  } catch (e) {
    this.wtReady = false;
    this.stats.lastError = `connect: ${String(e)}`;
    this.exitReason = 'transport-down';
    logClientEvent('wt-close', `connect failed: ${String(e)}`);
    this.setState(false, this.stats.lastError);
  }
}

// ---- incoming datagrams (RTT echoes) -------------------------------------
export async function readDatagramsImpl(this: StreamClient, wt: WebTransport) {
  try {
    const r = (wt.datagrams.readable as ReadableStream<Uint8Array>).getReader();
    for (;;) {
      const { value, done } = await r.read();
      if (done || this.disposed || this.wt !== wt) break;
      this.datagramsSeen++;
      if (value && value.length >= 5 && value[0] === T_PING) {
        const seq = (value[1] | (value[2] << 8) | (value[3] << 16) | (value[4] << 24)) >>> 0;
        const w = this.pingWaiters.get(seq);
        if (w) { w(performance.now()); this.pingWaiters.delete(seq); }
      }
    }
  } catch { /* stream gone */ }
}

// ---- incoming uni-streams (video AUs, and audio when tagged) -------------
export async function readIncomingStreamsImpl(this: StreamClient, wt: WebTransport) {
  try {
    const streams = wt.incomingUnidirectionalStreams.getReader();
    for (;;) {
      const { value, done } = await streams.read();
      if (done || this.disposed || this.wt !== wt) break;
      // Feed the poisoned-session watchdog: every accepted stream counts.
      this.uniStreamsSeen++;
      this.totalUniStreamsSeen++;
      this.lastUniStreamAt = performance.now();
      // Each stream is handled independently so a slow audio stream can't stall
      // per-frame video streams (and vice-versa).
      void this.handleStream(value as unknown as ReadableStream<Uint8Array>);
    }
  } catch { /* accept loop gone */ }
}

// ---- Firefox poisoned-session watchdog + silent rebuild -------------------
/** Arm the per-session delivery watchdog. Disarms itself as soon as the
 *  session proves healthy (> FF_STALL_MAX_STREAMS streams accepted) or the
 *  session is replaced/disposed; fires rebuildPoisonedSession() when the
 *  incoming uni-stream feed is silent past FF_STALL_QUIET_MS with at most
 *  FF_STALL_MAX_STREAMS streams ever delivered (the primed key AU + slack). */
export function armFfStallWatchdogImpl(this: StreamClient, wt: WebTransport) {
  if (this.ffStallTimer) { clearInterval(this.ffStallTimer); this.ffStallTimer = 0; }
  this.ffStallTimer = window.setInterval(() => {
    if (this.disposed || this.wt !== wt) {
      clearInterval(this.ffStallTimer); this.ffStallTimer = 0;
      return;
    }
    if (this.uniStreamsSeen > FF_STALL_MAX_STREAMS) {
      // Healthy session — delivery works; the startup race decided in our favor.
      clearInterval(this.ffStallTimer); this.ffStallTimer = 0;
      return;
    }
    const quietSince = Math.max(this.lastUniStreamAt, this.sessionReadyAt);
    if (performance.now() - quietSince >= FF_STALL_QUIET_MS) {
      clearInterval(this.ffStallTimer); this.ffStallTimer = 0;
      this.rebuildPoisonedSession(wt);
    }
  }, FF_STALL_CHECK_MS);
}

/** Tear down a session whose incoming uni-stream delivery is dead and connect
 *  a fresh one, WITHOUT surfacing a disconnect (the decoder + UI state carry
 *  over; the new session re-primes a key AU and painting resumes). */
export function rebuildPoisonedSessionImpl(this: StreamClient, oldWt: WebTransport) {
  if (this.disposed || this.wt !== oldWt) return;
  const maxRebuilds = FF_STALL_MAX_REBUILDS;
  if (this.sessionRebuilds >= maxRebuilds) {
    logClientEvent(
      'ff-session-giveup',
      `incoming video delivery still stalled (${this.uniStreamsSeen} current streams, ${this.totalUniStreamsSeen} total, framesRecv=${this.stats.framesRecv}) — rebuild budget ${this.sessionRebuilds}/${maxRebuilds} exhausted`,
    );
    return;
  }
  this.sessionRebuilds++;
  logClientEvent(
    'ff-session-rebuild',
    `incoming video delivery stalled (${this.uniStreamsSeen} current streams, ${this.totalUniStreamsSeen} total, framesRecv=${this.stats.framesRecv}) — rebuild ${this.sessionRebuilds}/${maxRebuilds}`,
  );
  // Detach FIRST so the old session's closed-handlers and read loops see
  // `this.wt !== oldWt` and no-op instead of reporting a drop.
  this.wt = null;
  this.wtReady = false;
  try { void this.dgWriter?.close().catch(() => { /* session gone */ }); } catch { /* noop */ }
  this.dgWriter = null;
  for (const w of this.inputWriters.values()) {
    try { void w.close().catch(() => { /* session gone */ }); } catch { /* noop */ }
  }
  this.inputWriters.clear();
  try { oldWt.close(); } catch { /* noop */ }
  void this.connect();
}

export async function handleStreamImpl(this: StreamClient, rs: ReadableStream<Uint8Array>) {
  try {
    if (this.wireVersion < 2) {
      // Legacy: whole stream is one video AU (header + Annex-B).
      const reader = rs.getReader();
      const buf = await new ByteReader(reader).readToEnd();
      this.feedVideoAU(buf);
      return;
    }
    // Tagged: first byte selects the payload kind.
    const br = new ByteReader(rs.getReader());
    const kind = await br.readU8();
    if (kind === KIND_VIDEO) {
      this.feedVideoAU(await br.readToEnd());
    } else if (kind === KIND_AUDIO) {
      await this.audioPlayer.handleStream(br);
    } else if (kind === KIND_PARAMS) {
      await this.handleParamsStream(br);
    } else {
      await br.readToEnd(); // unknown kind → drain + drop
    }
  } catch (e) {
    this.stats.lastError = `stream: ${String(e)}`;
  }
}

/** Surface one terminal state for a transport that has become unusable even
 *  though Firefox/QUIC has not settled `wt.closed` yet. The React hook owns the
 *  retry and will dispose this client after receiving onState(false). */
export function dropStaleSessionImpl(this: StreamClient, reason: 'ping-timeout' | 'stream-stalled', detail: string) {
  if (this.disposed || this.transportDown || !this.wt) return;
  this.transportDown = true;
  this.exitReason = reason;
  this.banner = 'reconnecting';
  logClientEvent('wt-close', `${reason}: ${detail}`);
  this.setState(false, detail);
  try { this.wt.close(); } catch { /* already gone */ }
}
