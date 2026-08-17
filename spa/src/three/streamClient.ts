// ============================================================================
//  streamClient — framework-free WebTransport + WebCodecs client for a
//  streamhost station (the ~6×-faster replacement for neko's WebRTC transport).
//  ---------------------------------------------------------------------------
//  This is the validated prototype `streamhost/web/client.html` refactored into
//  a typed, reusable module. It owns ONLY the wire + codecs; it has no React and
//  no knowledge of the StreamControlHandle. The controller (useStreamControl.ts)
//  and the hook (useStreamhostSession.ts) sit on top of it.
//
//  The class was decomposed (2026-07) into cohesive ./streamClient/ modules —
//  transport (QUIC session), videoDecode (WebCodecs feed + KIND_PARAMS), abr
//  (measure/report/scorer/banner), audioPlayer (Opus→WebAudio), plus the pure
//  signal / format / scoring / byteReader / constants / types helpers. This file
//  keeps the StreamClient state + public API and the input-send / telemetry /
//  lifecycle glue; the transport/video/abr method bodies live in their modules
//  as `this`-typed implementation functions (identical behaviour, no state moved).
//
//  SIGNALING → ./streamClient/signal.ts. VIDEO IN (one H.264 Annex-B access unit
//  per unidirectional QUIC stream) → ./streamClient/videoDecode.ts + transport.ts.
//  INPUT OUT (compact little-endian records — matches streamhost/src/input.rs):
//    datagrams (unreliable, high-rate, < ~200 B so they fit path MTU):
//      type 1  mouse move ABSOLUTE : u16 x, u16 y, u32 cseq   (guest needs usb-tablet)
//      type 4  mouse move RELATIVE : i16 dx, i16 dy           (PS/2-only guests)
//      type 9  RTT ping            : u32 seq           (echoed back)
//    PER-TYPE reliable QUIC streams (Moonlight-style HOL avoidance): one CLIENT-
//    opened UNIDIRECTIONAL reliable stream per input CLASS (ICLASS_* tag), so a
//    retransmit on one class can't head-of-line-block another. Each stream is led
//    by a 1-byte CLASS tag, then carries [len u16 LE][record] framing:
//      ICLASS_KEY=1    → type 3  key    : u8 down, u16 keycode (XT set1; 0xE0xx=ext)
//      ICLASS_BUTTON=2 → type 2  mouse button : u8 button, u8 down, u16 x, u16 y, u32 cseq
//      ICLASS_WHEEL=3  → type 5  wheel  : i16 dx, i16 dy
//    Wheel (type 5) is a documented client→server wire EXTENSION; it is length-
//    prefixed so a server that does not yet decode it simply skips the record.
//
//  THE CLIENT IS AUTHORITATIVE OVER POINTER STATE, and `cseq` is how it says so.
//  Moves ride unreliable datagrams and buttons ride a reliable stream — two
//  transports the network is free to REORDER against each other, and only one of
//  which can drop. A press therefore used to race its own position: when the
//  button won, the daemon pressed at the PREVIOUS position and then slid the
//  cursor to the real one with the button held, which the guest reads as a drag
//  (measured on IRIX, 2026-08-05; see docs/lab/PEN-TAP-PLAN.md). Two properties
//  fix it here rather than with a server-side delay:
//    * a button record CARRIES the position it happens at, so a press is one
//      atomic reliable record and can never be separated from its coordinates;
//    * every position-bearing record carries a monotonic `cseq`, so the daemon
//      can DROP an absolute move that the client emitted before something it has
//      already applied. Stale motion is discarded instead of rewinding the
//      cursor under a held button.
//  Relative moves (type 4) deliberately carry no cseq: deltas accumulate, so a
//  late one is still owed to the guest and dropping it would lose motion.
// ============================================================================

import { AudioPlayer } from './streamClient/audioPlayer';
import {
  moveWireSnapshotImpl, noteMoveWireImpl, sendButtonImpl, sendKeyScancodeImpl,
  sendMoveAbsImpl, sendMoveRelImpl, sendWheelImpl,
} from './streamClient/inputWire';
import {
  connectImpl,
  readDatagramsImpl,
  readIncomingStreamsImpl,
  armFfStallWatchdogImpl,
  rebuildPoisonedSessionImpl,
  handleStreamImpl,
  dropStaleSessionImpl,
} from './streamClient/transport';
import {
  handleParamsStreamImpl,
  pickAccelImpl,
  noteDecodeFailureImpl,
  setupVideoDecoderImpl,
  maybeConfigureForKeyImpl,
  configureAvcImpl,
  configureAnnexbImpl,
  feedVideoAUImpl,
} from './streamClient/videoDecode';
import { tickStatsImpl, updateBannerImpl, sendStatsImpl } from './streamClient/abr';
import { VideoAuGate } from './streamClient/auGate';
import { StreamTelemetry } from './streamClient/telemetry';
import {
  T_PING,
  IS_FIREFOX,
  IS_FIREFOX_ANDROID,
  NO_VIDEO_DEADLINE_MS,
} from './streamClient/constants';
import { flushNow, logClientEvent } from './clientDebug';
import { recordKeyEdge } from '../input/keyRecorder';
import type { ByteReader } from './streamClient/byteReader';
import type {
  StreamBannerState,
  StreamClientConfig,
  StreamClientStats,
  StreamDecoderUnsupportedReason,
  StreamEncoderParams,
  StreamExitReason,
  StreamMetrics,
  StreamServerStats,
  StreamVideoParams,
} from './streamClient/types';

// ---- Public API re-exports (stable import surface for StreamView/useStream*) --
export { codecStringFor, profileName, levelName, presetName } from './streamClient/format';
export type {
  StreamVideoParams,
  StreamBannerState,
  StreamDecoderUnsupportedReason,
  StreamExitReason,
  StreamEncoderParams,
  StreamServerStats,
  StreamMetrics,
  StreamClientStats,
  StreamClientConfig,
} from './streamClient/types';

export class StreamClient {
  cfg: StreamClientConfig;
  wt: WebTransport | null = null;
  dgWriter: WritableStreamDefaultWriter<Uint8Array> | null = null;
  // Per-type reliable input: one client-opened unidirectional stream per input
  // CLASS (keyed by its ICLASS_* tag). Split off the old single reliable channel so
  // a retransmit on one class can't HOL-block another. Populated in connect().
  inputWriters = new Map<number, WritableStreamDefaultWriter<Uint8Array>>();
  disposed = false;
  /** Terminal browser capability failure. Set before any transport is opened. */
  decoderUnsupportedReason: StreamDecoderUnsupportedReason | null = null;

  wireVersion = 1;
  videoDecoder: VideoDecoder | null = null;
  videoReady = false;

  /** Opus audio → WebAudio pipeline (own state); constructed below. */
  audioPlayer: AudioPlayer;

  pingSeq = 1;
  pingWaiters = new Map<number, (t: number) => void>();
  /** Monotonic ordering stamp across every position-bearing input record — the
   *  client's statement of what it sent first. See the wire block in the header. */
  cseq = 0;
  /** Last absolute position this client put on the wire; a button with no point
   *  of its own happens here. */
  lastAbsX = 0;
  lastAbsY = 0;
  lastRtt: number | null = null;
  consecutivePingTimeouts = 0;

  fCount = 0;
  fT = 0;
  stats: StreamClientStats = {
    connected: false, lastError: '-', framesRecv: 0, framesDecoded: 0, fps: 0,
    guestW: 0, guestH: 0, rttMs: null, sendBufferedAmount: null, audioEnabled: false,
  };

  // ---- codec / ABR wire state ----
  signalVideo: StreamVideoParams | null = null;
  encParams: StreamEncoderParams | null = null;
  serverStats: StreamServerStats | null = null;
  /** codec string currently applied to the VideoDecoder. */
  activeCodec = 'avc1.42e01e';
  /** codec we WANT (from params / signal); applied on the next keyframe. */
  desiredCodec = 'avc1.42e01e';
  // HW-DECODE CAPABILITY (probed once per client in connect()). Chrome >= 150
  // HARD-FAILS VideoDecoder.configure({hardwareAcceleration:'prefer-hardware'})
  // on GPU-less machines via the error CALLBACK (never the configure() throw), so
  // probe first and only nudge 'prefer-hardware' when the probe says it exists;
  // otherwise 'no-preference' (the UA still picks HW when available).
  hwDecodeOk: boolean | null = null;
  /** latched after an in-decoder unsupported-config error forced a SW rebuild. */
  hwFellBack = false;

  // ---- avc-mode decode state (Firefox fix: avcC description + AVCC chunks) --
  /** 'avc' = description+AVCC (the ONE interoperable path); 'annexb' = fallback. */
  decodePath: 'avc' | 'annexb' = 'avc';
  /** SPS/PPS bytes the current avcC description was built from. A byte change
   *  at a keyframe is the SINGLE reconfigure trigger (tier restarts emit a
   *  fresh SPS+PPS+IDR, so they reconfigure exactly once). */
  cachedSps: Uint8Array | null = null;
  cachedPps: Uint8Array | null = null;
  /** latched when an avc-mode configure THREW — stop retrying it every key. */
  avcConfigBroken = false;

  // ---- decoder-error visibility (STOP swallowing errors) --------------------
  decodeErrors = 0;
  lastDecodeError: string | null = null;
  /** consecutive configure/decode failures with no output frame in between. */
  consecutiveDecodeFails = 0;
  /** ≥ DECODER_FAIL_THRESHOLD consecutive failures ⇒ banner 'decoder-failed'. */
  decoderFailed = false;
  lastDecodeErrorLogAt = 0;

  // ---- decode-stat instrumentation (Section 2.2) ----
  statSeq = 0;
  lastReportAt = 0;
  recvBytesInterval = 0;
  recvKbps = 0;
  lastFrameId = -1;
  lastDecodedFrameId = 0;
  /** gap→keyframe decode gate: armed on frame_id gaps, cleared by key AUs
   *  (freeze on the last clean frame instead of painting broken references). */
  auGate = new VideoAuGate();
  missedInterval = 0;
  receivedInterval = 0;
  lossPct = 0;
  /** Rolling per-tick frame counts the REPORTED lossPct is measured over, so a
   *  low-fps station cannot report 100 % loss off a single dropped frame. */
  lossWindow: Array<{ at: number; recv: number; missed: number }> = [];
  /** Rolling diagnostic record behind the Ctrl+N overlay (passive recorder). */
  telemetry = new StreamTelemetry();
  /** performance.now() of the last periodic telemetry sample sent to /clientlog. */
  lastStatsLogAt = 0;
  // L-1: server-known egress skips must not read as network loss. `serverStats`
  // (KIND_PARAMS subtype 2) carries the CUMULATIVE per-session skip count at 1 Hz;
  // we diff it into a CREDIT bucket and spend that credit against the 100ms
  // gap-derived misses in tickStats — spreading the coarse 1 Hz lump across the
  // ticks where the gaps actually appear. Both stay 0 on a LAN (never skips).
  lastServerSkipTotal = 0;
  serverSkipCredit = 0;
  // decode-time diff: capture_ts (µs) → performance.now() at decode() submit.
  submitTimes = new Map<number, number>();
  decodeTimeSum = 0;
  decodeCountInterval = 0;
  decodeMs = 0;
  decodeFps = 0;
  framesDropped = 0;
  freezeCount = 0;
  freezeInInterval = false;
  frozen = false;
  lastDecodeOutAt = 0;
  /** last silent-stall decoder rebuild (rate limit for the self-heal). */
  lastStallRebuildAt = 0;
  lastAuAt = 0;

  // ---- client-local `el` scorer (Section 2.3) EWMA state ----
  scoreInit = false;
  sLatency = 100;
  sLoss = 100;
  sBandwidth = 100;
  sOverall = 100;
  banner: StreamBannerState = 'good';
  belowSince = 0;
  aboveSince = 0;
  transportDown = false;
  /** structured cause of the last drop (Section: StreamExitReason), or null. */
  exitReason: StreamExitReason | null = null;
  /** idle-frame-stall watchdog latch (Item 4). Distinct from ping liveness. */
  frameStalled = false;

  // ---- Firefox poisoned-session watchdog state (see FF_STALL_* in constants) ----
  /** incoming uni-streams accepted on the CURRENT session. */
  uniStreamsSeen = 0;
  /** performance.now() of the last accepted incoming uni-stream. */
  lastUniStreamAt = 0;
  /** performance.now() when the current session's wt.ready resolved. */
  sessionReadyAt = 0;
  /** watchdog interval id (Firefox only), 0 when disarmed. */
  ffStallTimer = 0;
  /** cumulative poisoned-session rebuilds (telemetry + retry cap). */
  sessionRebuilds = 0;
  /** all incoming uni-streams accepted across rebuilt sessions. */
  totalUniStreamsSeen = 0;
  /** all incoming datagrams accepted across rebuilt sessions. */
  datagramsSeen = 0;
  /** complete video AUs received across rebuilt sessions. */
  keyAUsSeen = 0;
  /** number of decoder-config telemetry events emitted by this client. */
  decoderConfigsSeen = 0;
  /** Explicit promise state: WebTransport exposes promises, not a state getter. */
  wtReady = false;
  /** QUIC policy advertised by the currently selected station. */
  serverMaxUdpPayloadSize: number | null = null;
  serverMtuDiscovery: boolean | null = null;
  /** one-shot startup diagnostic, shared across transparent session rebuilds. */
  noVideoTimer = 0;
  noVideoLogged = false;
  lifecycleHooksInstalled = false;

  // ---- move-datagram wire telemetry (pointer diagnostics) -------------------
  // Cheap client-lifetime counters read by the pointer telemetry stroke
  // accumulator (input/pointerTelemetry) to attribute lost drag samples to the
  // datagram wire vs the event source. Bumped in sendMoveAbs/sendMoveRel and in
  // the (otherwise fire-and-forget) writeDatagram write promise.
  /** total move datagrams enqueued via sendMoveAbs/sendMoveRel. */
  moveSent = 0;
  /** datagram write promises that later REJECTED (session gone / TTL drop). */
  moveRejected = 0;
  /** lowest dgWriter.desiredSize sampled at a move enqueue (∞ until sampled;
   *  ≤ 0 ⇒ the datagram queue is under backpressure). */
  moveDesiredMin = Number.POSITIVE_INFINITY;

  readonly onPageHide = () => {
    this.emitNoVideo('pagehide');
    flushNow(true);
  };

  readonly onVisibilityChange = () => {
    if (document.visibilityState !== 'hidden') return;
    this.emitNoVideo('visibility-hidden');
    flushNow(true);
  };

  /** Tiny eval surface for the operator command. TypeScript `private` fields
   * are otherwise unreachable without depending on React internals. Installed
   * only for the affected browser class. */
  readonly debugProbe = () => ({
    wtPresent: !!this.wt,
    wtReady: this.wtReady,
    uniStreamsSeen: this.uniStreamsSeen,
    totalUniStreamsSeen: this.totalUniStreamsSeen,
    datagramsSeen: this.datagramsSeen,
    framesRecv: this.stats.framesRecv,
    keyAUsSeen: this.keyAUsSeen,
    framesDecoded: this.stats.framesDecoded,
    decoderConfigsSeen: this.decoderConfigsSeen,
    sessionRebuilds: this.sessionRebuilds,
    serverMaxUdpPayloadSize: this.serverMaxUdpPayloadSize,
    serverMtuDiscovery: this.serverMtuDiscovery,
    lastError: this.stats.lastError,
  });

  constructor(cfg: StreamClientConfig) {
    this.cfg = cfg;
    // onError mirrors the original inline `this.stats.lastError = …` writes.
    this.audioPlayer = new AudioPlayer((msg) => { this.stats.lastError = msg; });
    // Feature detection, deliberately not a browser/UA check. This also catches
    // Firefox for Android, where WebTransport exists but VideoDecoder does not.
    if (typeof VideoDecoder === 'undefined') {
      this.decoderUnsupportedReason = 'api-unavailable';
      this.banner = 'decoder-unsupported';
      this.stats.lastError = 'the required WebCodecs VideoDecoder API is unavailable';
    }
    if (IS_FIREFOX_ANDROID) {
      (globalThis as typeof globalThis & {
        __kernelHiveStreamDebug?: () => Record<string, unknown>;
      }).__kernelHiveStreamDebug = this.debugProbe;
    }
  }

  // ---- startup no-video telemetry (Firefox-Android / capability diagnostics) --
  /** Arm one client-lifetime startup deadline. Transparent Firefox transport
   * rebuilds deliberately do not reset it: the first report must capture the
   * failure promptly, rather than being postponed forever by retries. */
  armNoVideoTelemetry() {
    if (this.noVideoTimer || this.noVideoLogged || this.decoderConfigsSeen > 0) return;
    if (!this.lifecycleHooksInstalled) {
      this.lifecycleHooksInstalled = true;
      window.addEventListener('pagehide', this.onPageHide);
      document.addEventListener('visibilitychange', this.onVisibilityChange);
    }
    this.noVideoTimer = window.setTimeout(() => {
      this.noVideoTimer = 0;
      this.emitNoVideo('deadline');
    }, NO_VIDEO_DEADLINE_MS);
  }

  /** Emit the exact pre-decoder receive state once. pagehide/visibility calls
   * this before beacon-flushing so even a short-lived mobile tab leaves evidence. */
  emitNoVideo(trigger: 'deadline' | 'pagehide' | 'visibility-hidden' | 'capability') {
    if (this.disposed || this.noVideoLogged || this.decoderConfigsSeen > 0) return;
    this.noVideoLogged = true;
    if (this.noVideoTimer) { clearTimeout(this.noVideoTimer); this.noVideoTimer = 0; }
    const decoderAvailable = typeof VideoDecoder !== 'undefined';
    logClientEvent(
      'no-video',
      `trigger=${trigger}, wtReady=${this.wtReady}, uniStreamsSeen=${this.uniStreamsSeen}, totalUniStreamsSeen=${this.totalUniStreamsSeen}, datagramsSeen=${this.datagramsSeen}, framesRecv=${this.stats.framesRecv}, keyAUsSeen=${this.keyAUsSeen}, sessionRebuilds=${this.sessionRebuilds}, maxUdpPayload=${this.serverMaxUdpPayloadSize ?? 'unknown'}, mtud=${this.serverMtuDiscovery ?? 'unknown'}, VideoDecoder=${decoderAvailable}, firefox=${IS_FIREFOX}, firefoxAndroid=${IS_FIREFOX_ANDROID}, decoderUnsupported=${this.decoderUnsupportedReason ?? 'none'}, codec=${this.desiredCodec}`,
    );
    // This event is deliberately small; ship it immediately so a mobile tab
    // closed before the normal batch interval still leaves decisive evidence.
    flushNow(true);
  }

  /** Keep the no-video deadline precisely aligned with decoder-config telemetry. */
  logDecoderConfig(detail: string) {
    this.decoderConfigsSeen++;
    if (this.noVideoTimer) { clearTimeout(this.noVideoTimer); this.noVideoTimer = 0; }
    logClientEvent('decoder-config', detail);
  }

  getStats(): StreamClientStats {
    this.stats.connected = !!this.wt && !this.disposed;
    this.stats.rttMs = this.lastRtt;
    this.stats.audioEnabled = this.audioPlayer.isEnabled();
    return { ...this.stats };
  }
  getResolution(): { w: number; h: number } {
    return { w: this.stats.guestW || 0, h: this.stats.guestH || 0 };
  }
  // Native guest console geometry (KIND_PARAMS subtype-1 native tail), used for the
  // absolute-pointer coordinate space so abs coords span QEMU's full live surface
  // even when ABR steps the encoded resolution below native. Falls back to the
  // decoded dims when the native tail is absent (old server / pre-params).
  getNativeResolution(): { w: number; h: number } {
    const nw = this.encParams?.nativeWidth ?? 0;
    const nh = this.encParams?.nativeHeight ?? 0;
    if (nw > 0 && nh > 0) return { w: nw, h: nh };
    return this.getResolution();
  }
  isConnected(): boolean {
    return !!this.wt && !this.disposed && this.stats.connected;
  }

  setState(connected: boolean, lastError: string) {
    this.stats.connected = connected;
    if (lastError) this.stats.lastError = lastError;
    try { this.cfg.onState?.(connected, this.stats.lastError, this.exitReason); } catch { /* noop */ }
  }

  /** Structured cause of the last transport drop / liveness loss, or null. */
  getExitReason(): StreamExitReason | null { return this.exitReason; }
  /** idle-frame-stall watchdog flag (Item 4) — true when no decoded frame has
   *  painted for > FRAME_STALL_MS while the transport is open. Detector only. */
  getFrameStalled(): boolean { return this.frameStalled; }

  // ---- transport / session lifecycle (impls in ./streamClient/transport) ----
  connect(): Promise<void> { return connectImpl.call(this); }
  readDatagrams(wt: WebTransport): Promise<void> { return readDatagramsImpl.call(this, wt); }
  readIncomingStreams(wt: WebTransport): Promise<void> { return readIncomingStreamsImpl.call(this, wt); }
  armFfStallWatchdog(wt: WebTransport): void { armFfStallWatchdogImpl.call(this, wt); }
  rebuildPoisonedSession(oldWt: WebTransport): void { rebuildPoisonedSessionImpl.call(this, oldWt); }
  handleStream(rs: ReadableStream<Uint8Array>): Promise<void> { return handleStreamImpl.call(this, rs); }
  handleParamsStream(br: ByteReader): Promise<void> { return handleParamsStreamImpl.call(this, br); }

  // ---- H.264 video decode (impls in ./streamClient/videoDecode) ----
  pickAccel(): 'prefer-hardware' | 'no-preference' { return pickAccelImpl.call(this); }
  noteDecodeFailure(msg: string): void { noteDecodeFailureImpl.call(this, msg); }
  setupVideoDecoder(): void { setupVideoDecoderImpl.call(this); }
  maybeConfigureForKey(au: Uint8Array): void { maybeConfigureForKeyImpl.call(this, au); }
  configureAvc(sps: Uint8Array, pps: Uint8Array): void { configureAvcImpl.call(this, sps, pps); }
  configureAnnexb(codec: string, why: string): void { configureAnnexbImpl.call(this, codec, why); }
  feedVideoAU(bytes: Uint8Array): void { feedVideoAUImpl.call(this, bytes); }

  // ---- Opus audio (delegates to AudioPlayer) ----
  setAudioEnabled(on: boolean) {
    this.audioPlayer.setEnabled(on);
    this.stats.audioEnabled = on;
  }
  isAudioEnabled(): boolean { return this.audioPlayer.isEnabled(); }

  // ---- input senders ------------------------------------------------------
  /** Next ordering stamp. Wraps at 2^32 (~50 days of continuous 1 kHz motion);
   *  the daemon compares with a signed window so the wrap is not a cliff. */
  nextCseq(): number {
    this.cseq = (this.cseq + 1) >>> 0;
    return this.cseq;
  }
  writeDatagram(b: Uint8Array) {
    if (!this.dgWriter || this.disposed) return;
    // Fire-and-forget (unchanged): we only OBSERVE the write promise for the
    // diagnostic reject counter — never await it — so send stays non-blocking.
    try { void this.dgWriter.write(b).then(() => { /* delivered */ }, () => { this.moveRejected++; }); }
    catch { /* dropped */ }
  }
  // Send one length-prefixed record on the reliable stream for its input CLASS.
  // Each class rides its own ordered uni stream, so records within a class keep
  // order while a stall on one class can't head-of-line-block another.
  writeReliableClass(cls: number, rec: Uint8Array) {
    const w = this.inputWriters.get(cls);
    if (!w || this.disposed) return;
    const b = new Uint8Array(2 + rec.length);
    b[0] = rec.length & 0xff; b[1] = (rec.length >> 8) & 0xff;
    b.set(rec, 2);
    try { void w.write(b); } catch { /* dropped */ }
  }

  sendMoveAbs(x: number, y: number) { sendMoveAbsImpl(this, x, y); }
  sendMoveRel(dx: number, dy: number) { sendMoveRelImpl(this, dx, dy); }
  noteMoveWire() { noteMoveWireImpl(this); }
  moveWireSnapshot(): { sent: number; rejected: number; desiredSizeMin: number | null } {
    return moveWireSnapshotImpl(this);
  }
  /** Button edge, carrying the position it happens at (see inputWire). */
  sendButton(button: number, down: boolean, x?: number, y?: number) {
    sendButtonImpl(this, button, down, x, y);
  }
  sendKeyScancode(keycode: number, down: boolean) {
    // Keyboard-lag evidence chain, client link: record the edge exactly as it
    // goes on the wire (OSK, typeText chords and physical keys all funnel here).
    recordKeyEdge(keycode, down);
    sendKeyScancodeImpl(this, keycode, down);
  }
  sendWheel(dx: number, dy: number) { sendWheelImpl(this, dx, dy); }
  /** Send an RTT ping datagram and resolve the round-trip in ms (or null). */
  async pingRtt(timeoutMs = 500): Promise<number | null> {
    if (!this.dgWriter || this.disposed) return null;
    const seq = this.pingSeq++ >>> 0;
    const b = new Uint8Array(5); b[0] = T_PING;
    new DataView(b.buffer).setUint32(1, seq, true);
    const t0 = performance.now();
    const echoed = new Promise<number>((res) => this.pingWaiters.set(seq, res));
    this.writeDatagram(b);
    const t1 = await Promise.race([
      echoed,
      new Promise<number>((r) => setTimeout(() => r(-1), timeoutMs)),
    ]);
    this.pingWaiters.delete(seq);
    if (t1 > 0) {
      this.lastRtt = t1 - t0;
      this.consecutivePingTimeouts = 0;
      return this.lastRtt;
    }
    // 3 consecutive type-9 timeouts ⇒ treat the link as gone (Section 2.6).
    this.consecutivePingTimeouts++;
    if (this.consecutivePingTimeouts >= 3 && !this.transportDown) {
      this.dropStaleSession('ping-timeout', 'tile stopped responding to liveness pings');
    }
    return null;
  }

  dropStaleSession(reason: 'ping-timeout' | 'stream-stalled', detail: string): void {
    dropStaleSessionImpl.call(this, reason, detail);
  }

  // ========================================================================
  //  ABR / QUALITY — client MEASURES + REPORTS; server STEPS (impls in
  //  ./streamClient/abr; pure scorer math in ./streamClient/scoring)
  // ========================================================================
  tickStats(): void { tickStatsImpl.call(this); }
  updateBanner(now: number): void { updateBannerImpl.call(this, now); }
  sendStats(decodeQueue: number, _missed: number): void { sendStatsImpl.call(this, decodeQueue, _missed); }

  getBannerState(): StreamBannerState { return this.banner; }
  getDecoderUnsupportedReason(): StreamDecoderUnsupportedReason | null {
    return this.decoderUnsupportedReason;
  }

  /** The full HUD metric snapshot (Section 4). */
  getMetrics(): StreamMetrics {
    const decodeQueue = this.videoDecoder ? (this.videoDecoder.decodeQueueSize || 0) : 0;
    return {
      enc: this.encParams,
      server: this.serverStats,
      recvKbps: this.recvKbps,
      decodeFps: this.decodeFps,
      decodeMs: this.decodeMs,
      decodeQueue,
      framesDropped: this.framesDropped,
      freezeCount: this.freezeCount,
      lossPct: this.lossPct,
      signal: this.signalVideo,
      latencyScore: Math.round(this.sLatency),
      lossScore: Math.round(this.sLoss),
      bandwidthScore: Math.round(this.sBandwidth),
      overallScore: Math.round(this.sOverall),
      banner: this.banner,
      stalled: this.frameStalled,
      decodeErrors: this.decodeErrors,
      lastDecodeError: this.lastDecodeError,
      decodePath: this.decodePath,
      sessionRebuilds: this.sessionRebuilds,
      diag: this.telemetry.snapshot(performance.now()),
    };
  }

  /** Last decoder error message (metrics/HUD/chip), or null. */
  getLastDecodeError(): string | null { return this.lastDecodeError; }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.wtReady = false;
    if (this.ffStallTimer) { clearInterval(this.ffStallTimer); this.ffStallTimer = 0; }
    if (this.noVideoTimer) { clearTimeout(this.noVideoTimer); this.noVideoTimer = 0; }
    if (this.lifecycleHooksInstalled) {
      window.removeEventListener('pagehide', this.onPageHide);
      document.removeEventListener('visibilitychange', this.onVisibilityChange);
      this.lifecycleHooksInstalled = false;
    }
    if (IS_FIREFOX_ANDROID) {
      const g = globalThis as typeof globalThis & {
        __kernelHiveStreamDebug?: () => Record<string, unknown>;
      };
      if (g.__kernelHiveStreamDebug === this.debugProbe) delete g.__kernelHiveStreamDebug;
    }
    this.setState(false, this.stats.lastError);
    try { this.videoDecoder?.close(); } catch { /* noop */ }
    this.videoDecoder = null;
    this.audioPlayer.dispose();
    try { void this.dgWriter?.close().catch(() => { /* session gone */ }); } catch { /* noop */ }
    this.dgWriter = null;
    for (const w of this.inputWriters.values()) {
      try { void w.close().catch(() => { /* session gone */ }); } catch { /* noop */ }
    }
    this.inputWriters.clear();
    this.pingWaiters.clear();
    this.submitTimes.clear();
    try { this.wt?.close(); } catch { /* noop */ }
    this.wt = null;
  }
}
