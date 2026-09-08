// Native-decoder WebRTC fallback for streamhost stations.
//
// This path is entered only when VideoDecoder is absent. Every streamhost signal
// document advertises the same platform bridge; capable browsers never execute
// this class. Recovery owns fresh per-attempt PeerConnections so an ICE failure
// never requires a page reload.

import { flushNow, logClientEvent } from './clientDebug';
import { WebRtcFallbackInputClient, type FallbackInputSink } from './webRtcFallbackInput';

const PLAYOUT_DELAY_URI = 'http://www.webrtc.org/experiments/rtp-hdrext/playout-delay';
const ICE_GATHER_TIMEOUT_MS = 12_000;
const STATS_MS = 1_000;
const DISCONNECTED_GRACE_MS = 1_500;
const DECODE_STALL_MS = 6_000;
const RECONNECT_BACKOFF_MS = [0, 500, 1_000, 2_000, 4_000, 8_000];
const MAX_INITIAL_FAILURES = 6;

interface WebRtcSignal {
  offerUrl: string;
  iceServers?: RTCIceServer[];
  jitterBufferTargetMs?: number;
}

interface SignalDocument {
  webrtc?: WebRtcSignal;
  /** The session ticket the serving plane minted for this connect (the same
   *  `/wt/<exp>.<nonce>.<sig>` the WebTransport client uses as its path). On the
   *  fallback it becomes the first message on the reliable input channel so the
   *  daemon can verify an unticketed peer cannot inject input (empty on a
   *  keyless LAN station, where the daemon's ticket gate is inert). */
  path?: string;
}

interface AnswerDocument {
  type?: RTCSdpType;
  sdp?: string;
}

type WebRtcFallbackMediaState =
  | 'connecting'
  | 'live'
  | 'stalled'
  | 'reconnecting'
  | 'failed';

export interface WebRtcFallbackSnapshot {
  transport: 'webrtc-fallback';
  configured: boolean;
  mediaState: WebRtcFallbackMediaState;
  connectionState: RTCPeerConnectionState | 'new';
  iceConnectionState: RTCIceConnectionState | 'new';
  signalingState: RTCSignalingState | 'new';
  reconnectCount: number;
  reconnectAttempt: number;
  reconnectReason: string;
  lastFrameAtMs: number;
  jitterBufferTargetMs: number;
  receiverJitterBufferTarget: number | null;
  receiverPlayoutDelayHint: number | null;
  playoutDelayNegotiated: boolean;
  trackMuted: boolean | null;
  framesReceived: number;
  framesDecoded: number;
  peerFramesDecoded: number;
  framesDropped: number;
  framesPerSecond: number;
  packetsReceived: number;
  packetsLost: number;
  bytesReceived: number;
  jitterMs: number;
  jitterBufferMs: number;
  rttMs: number;
  codec: string;
  candidateType: string;
  protocol: string;
  /** Type and address:port of the bridge-side candidate the selected pair uses. */
  remoteCandidateType: string;
  remoteAddress: string;
  lastError: string;
}

export interface WebRtcFallbackCallbacks {
  onTrack: (stream: MediaStream, receiver: RTCRtpReceiver) => void;
  onState?: (
    state: WebRtcFallbackMediaState,
    error: string,
    snapshot: WebRtcFallbackSnapshot,
  ) => void;
}

type TunableReceiver = RTCRtpReceiver & {
  jitterBufferTarget?: number | null;
  playoutDelayHint?: number | null;
};

export class WebRtcFallbackClient {
  private pc: RTCPeerConnection | null = null;
  private receiver: TunableReceiver | null = null;
  private signal: WebRtcSignal | null = null;
  // INPUT PLANE (webRtcFallbackInput.ts): two DataChannels opened per attempt —
  // `input-rel` (unreliable, moves) and `input` (reliable, buttons/keys/wheel,
  // ticket-first). The adapter is stable and always writes the CURRENT pair.
  private inputRel: RTCDataChannel | null = null;
  private inputReliable: RTCDataChannel | null = null;
  private ticketPath = '';
  private ticketSent = false;
  private inputAdapter: WebRtcFallbackInputClient | null = null;
  // The bridge's Opus track, played through a dedicated (unmuted) element so
  // audio survives the muted-for-autoplay visible <video>. Owned here so the
  // control handle's setAudioEnabled has one place to reach.
  private audioEl: HTMLAudioElement | null = null;
  private audioOn = true;
  private statsTimer = 0;
  private reconnectTimer = 0;
  private disconnectedTimer = 0;
  private disposed = false;
  private configured = false;
  private generation = 0;
  private frameOffset = 0;
  private lastPeerFramesDecoded = 0;
  private lastPeerPacketsReceived = 0;
  private lastFrameProgressAt = 0;
  private lastEmittedState = '';
  private everLive = false;
  private callbacks: WebRtcFallbackCallbacks;
  private snapshot: WebRtcFallbackSnapshot = {
    transport: 'webrtc-fallback', configured: false, mediaState: 'connecting',
    connectionState: 'new', iceConnectionState: 'new', signalingState: 'new',
    reconnectCount: 0, reconnectAttempt: 0, reconnectReason: '', lastFrameAtMs: 0,
    jitterBufferTargetMs: 15, receiverJitterBufferTarget: null,
    receiverPlayoutDelayHint: null, playoutDelayNegotiated: false, trackMuted: null,
    framesReceived: 0, framesDecoded: 0, peerFramesDecoded: 0,
    framesDropped: 0, framesPerSecond: 0,
    packetsReceived: 0, packetsLost: 0, bytesReceived: 0,
    jitterMs: 0, jitterBufferMs: 0, rttMs: 0,
    codec: '', candidateType: '', protocol: '', remoteCandidateType: '', remoteAddress: '', lastError: '',
  };

  constructor(callbacks: WebRtcFallbackCallbacks) {
    this.callbacks = callbacks;
  }

  /** Returns false only for an old server that does not expose the platform
   * capability. Once configured, connection failures recover in-session and do
   * not reject this method after the initial signal fetch. */
  async connect(signalEndpoint: string): Promise<boolean> {
    const signalRes = await fetch(signalEndpoint, { cache: 'no-store' });
    if (!signalRes.ok) throw new Error(`signal ${signalRes.status}`);
    const signalDoc = await signalRes.json() as SignalDocument;
    const webRtc = signalDoc.webrtc;
    if (!webRtc?.offerUrl) return false;
    if (typeof RTCPeerConnection === 'undefined') {
      throw new Error('RTCPeerConnection is unavailable');
    }

    this.signal = webRtc;
    this.ticketPath = typeof signalDoc.path === 'string' ? signalDoc.path : '';
    this.configured = true;
    this.snapshot.configured = true;
    this.snapshot.jitterBufferTargetMs = Math.max(0, webRtc.jitterBufferTargetMs ?? 15);
    this.installDebugProbe();
    if (!this.statsTimer) {
      this.statsTimer = window.setInterval(() => { void this.collectStats(false); }, STATS_MS);
    }
    try {
      await this.startAttempt();
    } catch (error) {
      this.scheduleReconnect(`offer failed: ${String(error)}`);
    }
    return true;
  }

  private async startAttempt() {
    const webRtc = this.signal;
    if (!webRtc || this.disposed) return;
    this.clearReconnectTimers();
    this.closePeer();
    const generation = ++this.generation;
    this.snapshot.mediaState = this.snapshot.reconnectAttempt > 0 ? 'reconnecting' : 'connecting';
    this.snapshot.lastError = '';
    this.emitState(true);

    const pc = new RTCPeerConnection({
      iceServers: Array.isArray(webRtc.iceServers) ? webRtc.iceServers : [],
      iceTransportPolicy: 'all',
      bundlePolicy: 'max-bundle',
      rtcpMuxPolicy: 'require',
    });
    this.pc = pc;
    const transceiver = pc.addTransceiver('video', { direction: 'recvonly' });
    this.preferH264(transceiver);
    pc.addTransceiver('audio', { direction: 'recvonly' });
    this.openInputChannels(pc, generation);

    pc.ontrack = (event) => {
      if (!this.isCurrent(pc, generation) || event.track.kind !== 'video') return;
      const stream = event.streams[0] ?? new MediaStream([event.track]);
      this.receiver = event.receiver as TunableReceiver;
      this.applyLowLatencyFloor();
      this.snapshot.trackMuted = event.track.muted;
      event.track.onmute = () => {
        if (!this.isCurrent(pc, generation)) return;
        this.snapshot.trackMuted = true;
        this.markStalled('video track muted');
        this.scheduleReconnect('video track muted');
      };
      event.track.onunmute = () => {
        if (!this.isCurrent(pc, generation)) return;
        this.snapshot.trackMuted = false;
        this.emitState(true);
      };
      logClientEvent('webrtc-track', `kind=video id=${event.track.id} jitterFloorMs=${this.snapshot.jitterBufferTargetMs}`);
      this.attachAudio(stream);
      this.callbacks.onTrack(stream, event.receiver);
    };

    const stateChanged = () => {
      if (!this.isCurrent(pc, generation)) return;
      this.refreshPeerStates(pc);
      logClientEvent('webrtc-state', `pc=${pc.connectionState} ice=${pc.iceConnectionState} signaling=${pc.signalingState}`);
      if (pc.connectionState === 'failed' || pc.iceConnectionState === 'failed') {
        this.scheduleReconnect(`ICE failed (pc=${pc.connectionState}, ice=${pc.iceConnectionState})`);
        return;
      }
      if (pc.iceConnectionState === 'disconnected') {
        this.snapshot.mediaState = 'reconnecting';
        this.snapshot.reconnectReason = 'ICE disconnected';
        this.emitState(true);
        if (!this.disconnectedTimer) {
          this.disconnectedTimer = window.setTimeout(() => {
            this.disconnectedTimer = 0;
            if (this.isCurrent(pc, generation) && pc.iceConnectionState === 'disconnected') {
              this.scheduleReconnect('ICE disconnected');
            }
          }, DISCONNECTED_GRACE_MS);
        }
        return;
      }
      if (pc.connectionState === 'connected'
        && (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed')) {
        if (this.disconnectedTimer) {
          window.clearTimeout(this.disconnectedTimer);
          this.disconnectedTimer = 0;
        }
        this.snapshot.mediaState = this.snapshot.peerFramesDecoded > 0 ? 'live' : 'connecting';
        this.emitState(true);
        flushNow();
        void this.collectStats(true);
      } else {
        this.emitState(true);
      }
    };
    pc.onconnectionstatechange = stateChanged;
    pc.oniceconnectionstatechange = stateChanged;

    const offer = await pc.createOffer();
    if (!this.isCurrent(pc, generation)) return;
    this.snapshot.playoutDelayNegotiated = offer.sdp?.includes(PLAYOUT_DELAY_URI) ?? false;
    await pc.setLocalDescription(offer);
    await waitForIceGathering(pc, ICE_GATHER_TIMEOUT_MS);
    if (!this.isCurrent(pc, generation) || !pc.localDescription) return;

    logClientEvent(
      'webrtc-offer',
      `attempt=${this.snapshot.reconnectAttempt} playoutDelayOffered=${this.snapshot.playoutDelayNegotiated} iceServers=${webRtc.iceServers?.length ?? 0}`,
    );
    const answerRes = await fetch(webRtc.offerUrl, {
      method: 'POST',
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: pc.localDescription.type, sdp: pc.localDescription.sdp }),
    });
    if (!answerRes.ok) throw new Error(`WebRTC offer ${answerRes.status}`);
    const answer = await answerRes.json() as AnswerDocument;
    if (answer.type !== 'answer' || typeof answer.sdp !== 'string') {
      throw new Error('invalid WebRTC answer');
    }
    if (!this.isCurrent(pc, generation)) return;
    this.snapshot.playoutDelayNegotiated =
      this.snapshot.playoutDelayNegotiated && answer.sdp.includes(PLAYOUT_DELAY_URI);
    await pc.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
  }

  private isCurrent(pc: RTCPeerConnection, generation: number) {
    return !this.disposed && this.pc === pc && this.generation === generation;
  }

  private preferH264(transceiver: RTCRtpTransceiver) {
    try {
      const codecs = RTCRtpReceiver.getCapabilities?.('video')?.codecs ?? [];
      const h264 = codecs.filter((codec) => codec.mimeType.toLowerCase() === 'video/h264');
      if (h264.length && typeof transceiver.setCodecPreferences === 'function') {
        transceiver.setCodecPreferences(h264);
      }
    } catch (error) {
      logClientEvent('webrtc-codec-pref', `H264 preference unavailable: ${String(error)}`);
    }
  }

  private applyLowLatencyFloor() {
    const receiver = this.receiver;
    if (!receiver) return;
    const floorMs = this.snapshot.jitterBufferTargetMs;
    try { receiver.jitterBufferTarget = floorMs; } catch { /* engine may expose read-only */ }
    try { receiver.playoutDelayHint = floorMs / 1000; } catch { /* non-standard insurance */ }
    this.snapshot.receiverJitterBufferTarget = receiver.jitterBufferTarget ?? null;
    this.snapshot.receiverPlayoutDelayHint = receiver.playoutDelayHint ?? null;
  }

  // INPUT PLANE. The offer opens two DataChannels the daemon reads via the Pion
  // bridge, on the SAME wire WebTransport speaks: `input-rel` (unreliable,
  // ordered:false/maxRetransmits:0 — moves + re-home hint) and `input`
  // (reliable+ordered — buttons/keys/wheel). `input`'s FIRST message is the
  // ticket; the bridge only forwards, the daemon verifies.
  private openInputChannels(pc: RTCPeerConnection, generation: number) {
    this.ticketSent = false;
    this.inputRel = pc.createDataChannel('input-rel', { ordered: false, maxRetransmits: 0 });
    this.inputReliable = pc.createDataChannel('input', { ordered: true });
    this.inputRel.onopen = () => {
      if (this.isCurrent(pc, generation)) logClientEvent('webrtc-input', 'open label=input-rel');
    };
    this.inputRel.onclose = () => logClientEvent('webrtc-input', 'close label=input-rel');
    this.inputReliable.onopen = () => {
      if (!this.isCurrent(pc, generation)) return;
      // Ticket FIRST (ordered channel): the daemon reads the leading frame as the
      // credential, everything after it as records. Sent even when empty (keyless
      // LAN station) — the daemon's gate is inert there but still expects it.
      try { this.inputReliable?.send(this.ticketPath); this.ticketSent = true; } catch { /* raced closed */ }
      logClientEvent('webrtc-input', `open label=input ticket=${this.ticketPath ? 'present' : 'none'}`);
    };
    this.inputReliable.onclose = () => { this.ticketSent = false; logClientEvent('webrtc-input', 'close label=input'); };
  }

  writeInputDatagram(b: Uint8Array) { // FallbackInputSink write side
    if (this.inputRel?.readyState === 'open') { try { this.inputRel.send(b as ArrayBufferView<ArrayBuffer>); } catch { /* dropped */ } }
  }
  writeInputReliable(b: Uint8Array) {
    if (this.inputReliable?.readyState === 'open' && this.ticketSent) { try { this.inputReliable.send(b as ArrayBufferView<ArrayBuffer>); } catch { /* dropped */ } }
  }
  isInputConnected(): boolean {
    return this.inputReliable?.readyState === 'open' && this.ticketSent
      && this.snapshot.connectionState === 'connected' || false;
  }

  /** The transport-agnostic input client `createStreamController` consumes.
   *  Stable across reconnects — it always writes the CURRENT DataChannel pair. */
  inputClient(stationId: string | null): WebRtcFallbackInputClient {
    if (!this.inputAdapter) {
      const sink: FallbackInputSink = {
        writeInputDatagram: (b) => this.writeInputDatagram(b),
        writeInputReliable: (b) => this.writeInputReliable(b),
        fallbackAudioEnabled: () => this.audioOn,
        setFallbackAudioEnabled: (on) => this.setAudioEnabled(on),
        snapshot: () => this.getSnapshot(),
        isInputConnected: () => this.isInputConnected(),
      };
      this.inputAdapter = new WebRtcFallbackInputClient(sink, stationId);
    }
    return this.inputAdapter;
  }

  private attachAudio(stream: MediaStream) {
    if (this.audioEl) { try { this.audioEl.pause(); this.audioEl.srcObject = null; } catch { /* noop */ } }
    const el = document.createElement('audio');
    el.autoplay = true; el.muted = !this.audioOn; el.srcObject = stream;
    void el.play().catch(() => { /* browser may require another gesture */ });
    this.audioEl = el;
  }

  private setAudioEnabled(on: boolean) {
    this.audioOn = on;
    if (this.audioEl) this.audioEl.muted = !on;
  }

  private scheduleReconnect(reason: string) {
    if (this.disposed || !this.configured || this.reconnectTimer) return;
    if (!this.everLive && this.snapshot.reconnectAttempt >= MAX_INITIAL_FAILURES - 1) {
      this.snapshot.reconnectReason = reason;
      this.snapshot.lastError = reason;
      this.snapshot.mediaState = 'failed';
      this.closePeer();
      logClientEvent('webrtc-failed', `initialAttempts=${MAX_INITIAL_FAILURES} reason=${reason}`);
      this.emitState(true);
      return;
    }
    this.snapshot.reconnectCount += 1;
    this.snapshot.reconnectAttempt += 1;
    this.snapshot.reconnectReason = reason;
    this.snapshot.lastError = reason;
    this.snapshot.mediaState = 'reconnecting';
    this.closePeer();
    const delay = RECONNECT_BACKOFF_MS[Math.min(
      this.snapshot.reconnectAttempt - 1,
      RECONNECT_BACKOFF_MS.length - 1,
    )];
    logClientEvent('webrtc-reconnect', `attempt=${this.snapshot.reconnectAttempt} delayMs=${delay} reason=${reason}`);
    this.emitState(true);
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = 0;
      void this.startAttempt().catch((error) => {
        this.scheduleReconnect(`offer failed: ${String(error)}`);
      });
    }, delay);
  }

  private markStalled(reason: string) {
    if (this.disposed || this.snapshot.mediaState === 'reconnecting') return;
    this.snapshot.mediaState = 'stalled';
    this.snapshot.lastError = reason;
    this.snapshot.reconnectReason = reason;
    this.emitState(true);
  }

  private async collectStats(immediate: boolean) {
    const pc = this.pc;
    if (!pc || this.disposed) return;
    try {
      const report = await pc.getStats();
      if (pc !== this.pc || this.disposed) return;
      let codecId = '';
      let selectedLocalId = '';
      let selectedRemoteId = '';
      let peerFramesDecoded = 0;
      let peerPacketsReceived = 0;
      report.forEach((raw) => {
        const stat = raw as RTCStats & Record<string, unknown>;
        if (stat.type === 'inbound-rtp' && stat.kind === 'video') {
          const emitted = Number(stat.jitterBufferEmittedCount ?? 0);
          const peerFramesReceived = Number(stat.framesReceived ?? 0);
          peerFramesDecoded = Number(stat.framesDecoded ?? 0);
          peerPacketsReceived = Number(stat.packetsReceived ?? 0);
          this.snapshot.framesReceived = this.frameOffset + peerFramesReceived;
          this.snapshot.peerFramesDecoded = peerFramesDecoded;
          this.snapshot.framesDecoded = this.frameOffset + peerFramesDecoded;
          this.snapshot.framesDropped = Number(stat.framesDropped ?? 0);
          this.snapshot.framesPerSecond = Number(stat.framesPerSecond ?? 0);
          this.snapshot.packetsReceived = peerPacketsReceived;
          this.snapshot.packetsLost = Number(stat.packetsLost ?? 0);
          this.snapshot.bytesReceived = Number(stat.bytesReceived ?? 0);
          this.snapshot.jitterMs = Number(stat.jitter ?? 0) * 1000;
          this.snapshot.jitterBufferMs = emitted > 0
            ? Number(stat.jitterBufferDelay ?? 0) * 1000 / emitted
            : 0;
          codecId = String(stat.codecId ?? '');
        } else if (stat.type === 'candidate-pair' && stat.state === 'succeeded'
          && (stat.nominated === true || stat.selected === true)) {
          this.snapshot.rttMs = Number(stat.currentRoundTripTime ?? 0) * 1000;
          selectedLocalId = String(stat.localCandidateId ?? '');
          selectedRemoteId = String(stat.remoteCandidateId ?? '');
        }
      });
      report.forEach((raw) => {
        const stat = raw as RTCStats & Record<string, unknown>;
        if (stat.id === codecId) this.snapshot.codec = String(stat.mimeType ?? '');
        if (stat.id === selectedLocalId) {
          this.snapshot.candidateType = String(stat.candidateType ?? '');
          this.snapshot.protocol = String(stat.protocol ?? '');
        }
        // The REMOTE half of the selected pair is the bridge's address the
        // browser is actually talking to: the box's LAN address for a LAN
        // visitor, the edge's public address for a remote one. Without it a
        // failed ICE cannot be told apart from "the bridge offered only LAN
        // candidates" (docs/WEBRTC-PLATFORM.md §Remote visitors).
        if (stat.id === selectedRemoteId) {
          this.snapshot.remoteCandidateType = String(stat.candidateType ?? '');
          this.snapshot.remoteAddress = `${String(stat.address ?? stat.ip ?? '?')}:${String(stat.port ?? '?')}`;
        }
      });

      const now = Date.now();
      if (peerFramesDecoded > this.lastPeerFramesDecoded) {
        this.everLive = true;
        this.lastFrameProgressAt = now;
        this.snapshot.lastFrameAtMs = now;
        this.snapshot.mediaState = 'live';
        this.snapshot.reconnectAttempt = 0;
        this.snapshot.reconnectReason = '';
        this.snapshot.lastError = '';
        this.emitState(true);
      } else if (peerPacketsReceived > this.lastPeerPacketsReceived
        && this.lastFrameProgressAt > 0
        && now - this.lastFrameProgressAt >= DECODE_STALL_MS) {
        // A damage-gated station may legitimately send neither packets nor frames
        // while static. Only call it a decoder stall when RTP is still arriving.
        this.markStalled('RTP is arriving but decoded frames stopped advancing');
        this.scheduleReconnect('decoded frames stalled');
      }
      this.lastPeerFramesDecoded = peerFramesDecoded;
      this.lastPeerPacketsReceived = peerPacketsReceived;
      this.applyLowLatencyFloor();
      if (immediate || peerFramesDecoded > 0) {
        logClientEvent(
          'webrtc-stats',
          `media=${this.snapshot.mediaState} reconnect=${this.snapshot.reconnectAttempt} framesReceived=${this.snapshot.framesReceived} framesDecoded=${this.snapshot.framesDecoded} fps=${this.snapshot.framesPerSecond} packetsLost=${this.snapshot.packetsLost} jitterMs=${this.snapshot.jitterMs.toFixed(2)} jitterBufferMs=${this.snapshot.jitterBufferMs.toFixed(2)} rttMs=${this.snapshot.rttMs.toFixed(1)} candidate=${this.snapshot.candidateType}/${this.snapshot.protocol} remote=${this.snapshot.remoteCandidateType}@${this.snapshot.remoteAddress} playoutDelay=${this.snapshot.playoutDelayNegotiated}`,
        );
      }
    } catch (error) {
      if (pc !== this.pc || this.disposed) return;
      this.snapshot.lastError = String(error);
    }
  }

  private refreshPeerStates(pc: RTCPeerConnection) {
    this.snapshot.connectionState = pc.connectionState;
    this.snapshot.iceConnectionState = pc.iceConnectionState;
    this.snapshot.signalingState = pc.signalingState;
  }

  private emitState(force = false) {
    const signature = `${this.snapshot.mediaState}|${this.snapshot.reconnectAttempt}|${this.snapshot.lastError}`;
    if (!force && signature === this.lastEmittedState) return;
    this.lastEmittedState = signature;
    this.callbacks.onState?.(
      this.snapshot.mediaState,
      this.snapshot.lastError,
      this.getSnapshot(),
    );
  }

  private clearReconnectTimers() {
    if (this.reconnectTimer) {
      window.clearTimeout(this.reconnectTimer);
      this.reconnectTimer = 0;
    }
    if (this.disconnectedTimer) {
      window.clearTimeout(this.disconnectedTimer);
      this.disconnectedTimer = 0;
    }
  }

  private closePeer() {
    const pc = this.pc;
    if (!pc) return;
    this.frameOffset = this.snapshot.framesDecoded;
    this.lastPeerFramesDecoded = 0;
    this.lastPeerPacketsReceived = 0;
    this.lastFrameProgressAt = 0;
    this.snapshot.peerFramesDecoded = 0;
    this.receiver = null;
    this.pc = null;
    this.ticketSent = false;
    for (const ch of [this.inputRel, this.inputReliable]) {
      if (!ch) continue;
      ch.onopen = null; ch.onclose = null;
      try { ch.close(); } catch { /* noop */ }
    }
    this.inputRel = null;
    this.inputReliable = null;
    pc.ontrack = null;
    pc.onconnectionstatechange = null;
    pc.oniceconnectionstatechange = null;
    try { pc.close(); } catch { /* noop */ }
    this.snapshot.connectionState = 'closed';
    this.snapshot.iceConnectionState = 'closed';
    this.snapshot.signalingState = 'closed';
  }

  private installDebugProbe() {
    (globalThis as typeof globalThis & {
      __kernelHiveWebRtcDebug?: () => WebRtcFallbackSnapshot;
    }).__kernelHiveWebRtcDebug = () => this.getSnapshot();
  }

  getSnapshot(): WebRtcFallbackSnapshot {
    const pc = this.pc;
    if (pc) this.refreshPeerStates(pc);
    return { ...this.snapshot, configured: this.configured };
  }

  dispose() {
    this.disposed = true;
    this.clearReconnectTimers();
    if (this.statsTimer) { window.clearInterval(this.statsTimer); this.statsTimer = 0; }
    this.closePeer();
    if (this.audioEl) {
      try { this.audioEl.pause(); this.audioEl.srcObject = null; } catch { /* noop */ }
      this.audioEl = null;
    }
    const root = globalThis as typeof globalThis & { __kernelHiveWebRtcDebug?: () => WebRtcFallbackSnapshot };
    try { delete root.__kernelHiveWebRtcDebug; } catch { root.__kernelHiveWebRtcDebug = undefined; }
  }
}

async function waitForIceGathering(pc: RTCPeerConnection, timeoutMs: number) {
  if (pc.iceGatheringState === 'complete') return;
  await new Promise<void>((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      pc.removeEventListener('icegatheringstatechange', changed);
      reject(new Error('ICE gathering timed out'));
    }, timeoutMs);
    const changed = () => {
      if (pc.iceGatheringState !== 'complete') return;
      window.clearTimeout(timeout);
      pc.removeEventListener('icegatheringstatechange', changed);
      resolve();
    };
    pc.addEventListener('icegatheringstatechange', changed);
  });
}
