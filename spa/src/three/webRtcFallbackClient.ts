// Native-decoder WebRTC fallback for streamhost stations.
//
// This path is entered only when VideoDecoder is absent. Every streamhost signal
// document advertises the same platform bridge; capable browsers never execute
// this class. Recovery owns fresh per-attempt PeerConnections so an ICE failure
// never requires a page reload.

import { flushNow, logClientEvent } from './clientDebug';

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
    codec: '', candidateType: '', protocol: '', lastError: '',
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
        }
      });
      report.forEach((raw) => {
        const stat = raw as RTCStats & Record<string, unknown>;
        if (stat.id === codecId) this.snapshot.codec = String(stat.mimeType ?? '');
        if (stat.id === selectedLocalId) {
          this.snapshot.candidateType = String(stat.candidateType ?? '');
          this.snapshot.protocol = String(stat.protocol ?? '');
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
          `media=${this.snapshot.mediaState} reconnect=${this.snapshot.reconnectAttempt} framesReceived=${this.snapshot.framesReceived} framesDecoded=${this.snapshot.framesDecoded} fps=${this.snapshot.framesPerSecond} packetsLost=${this.snapshot.packetsLost} jitterMs=${this.snapshot.jitterMs.toFixed(2)} jitterBufferMs=${this.snapshot.jitterBufferMs.toFixed(2)} rttMs=${this.snapshot.rttMs.toFixed(1)} candidate=${this.snapshot.candidateType}/${this.snapshot.protocol} playoutDelay=${this.snapshot.playoutDelayNegotiated}`,
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
