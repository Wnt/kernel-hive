// ============================================================================
//  streamClient/types — the wire + HUD type surface for the streamhost client.
//  All interfaces/types are lifted verbatim from the original streamClient
//  god-module; the `Stream*` exports are the public API re-exported by
//  streamClient.ts, StreamLadderRung + StreamhostSignal are internal.
// ============================================================================

// One rung of the ABR ladder as advertised in signaling.json `video.ladder`.
export interface StreamLadderRung {
  tier: number;
  name: string;
  crf: number;
  maxKbps: number;
  minHeight?: number;
}

// The connect-time `video` object from signaling.json (Section 3.3). Every field
// is optional so an OLD server (no `video`) degrades to the baseline decoder.
export interface StreamVideoParams {
  /** authoritative decoder codec string, e.g. "avc1.640028" (High L4.0). */
  codec?: string;
  profile?: string;   // baseline | main | high
  preset?: string;    // ultrafast..veryslow
  tune?: string;      // zerolatency
  width?: number;
  height?: number;
  fpsCap?: number;
  keyframeMs?: number;
  gop?: number;
  defaultTier?: number;
  ladder?: StreamLadderRung[];
}

export interface StreamhostSignal {
  /** WebTransport URL, e.g. https://192.0.2.10:54095/wt */
  url: string;
  /** SHA-256 hash of the server's self-signed DER cert (raw bytes). */
  certHash: ArrayBuffer;
  /** 1 = legacy untagged video; 2 = tagged streams + audio; >=3 = + KIND_PARAMS. */
  wireVersion: number;
  /** server advertises an Opus audio path. */
  audio: boolean;
  /** connect-time encoder defaults + ABR ladder (Section 3.3), if present. */
  video?: StreamVideoParams;
  /** Server-published QUIC packet policy; absent on an old/unrestarted tile. */
  quic?: {
    maxUdpPayloadSize?: number;
    mtuDiscovery?: boolean;
  };
}

/** Banner state driven by the client-local `el` scorer (Section 2.6).
 *  'decoder-failed' is an EXPLICIT local-decoder state (≥3 consecutive
 *  configure/decode failures, zero output frames) so the UI can say
 *  "decoder failing" instead of blaming the network.
 *  'decoder-unsupported' is a terminal, UA-free capability failure: the
 *  WebCodecs VideoDecoder API is absent or rejects the advertised codec. */
export type StreamBannerState =
  | 'good'
  | 'spotty'
  | 'reconnecting'
  | 'decoder-failed'
  | 'decoder-unsupported';

export type StreamDecoderUnsupportedReason = 'api-unavailable' | 'codec-unsupported';

/**
 * Structured reason a session ended / dropped, so the UI can show a cause-specific
 * disconnect line instead of a bare "connection lost". Derived entirely on the
 * receive/liveness side (never the input path):
 *   - 'user-exit'       — the viewer left (Exit button / double-Esc); set by the UI.
 *   - 'transport-down'  — the WebTransport `closed` promise REJECTED (QUIC error /
 *                          server vanished) or connect() threw.
 *   - 'ping-timeout'    — ≥3 consecutive type-9 RTT pings timed out while the
 *                          transport still looked open (soft liveness loss).
 *   - 'server-finished' — the transport `closed` promise RESOLVED (clean close by
 *                          the server, e.g. the streamhost service stopped).
 *   - 'stream-stalled'  — WT stayed open but the keyframe heartbeat stopped
 *                          producing decoded frames (dead encoder/session).
 *   - 'device-sleep'    — the local device slept / was backgrounded (derived by the
 *                          UI from the visibility lifecycle).
 */
export type StreamExitReason =
  | 'user-exit'
  | 'transport-down'
  | 'ping-timeout'
  | 'stream-stalled'
  | 'device-sleep'
  | 'server-finished';

/** Current encoder params, decoded from KIND_PARAMS subtype 1 (Section 3.2). */
export interface StreamEncoderParams {
  tier: number;
  width: number;         // EFFECTIVE encoded width (downscaled at ABR tier 3).
  height: number;        // EFFECTIVE encoded height (downscaled at ABR tier 3).
  /** VBV -maxrate PEAK CAP in kbps (CRF+VBV mode: a ceiling, NOT a target). */
  targetKbps: number;
  crf: number;
  fpsCap: number;
  keyframeMs: number;
  profileIdc: number; // 66=baseline,77=main,100=high
  levelIdc: number;   // e.g. 0x28 = L4.0
  presetEnum: number; // 0=ultrafast..8=veryslow
  /** NATIVE capture width/height BEFORE any tier-3 downscale (wire extension;
   *  undefined against a server that doesn't emit the 4-byte native tail). */
  nativeWidth?: number;
  nativeHeight?: number;
}

/** Per-session server truth, from KIND_PARAMS subtype 2 (Section 3.2). */
export interface StreamServerStats {
  tier: number;
  targetKbps: number;
  measuredSendKbps: number;
  pathRttUs: number;
  pathCwnd: number;
  pathLost: number;
  latencyScore: number;
  lossScore: number;
  bandwidthScore: number;
  overallScore: number;
  qp: number; // 0xFF = unknown
  /** L-1: cumulative per-session egress SKIPS the server took (backlog gate drops
   *  + ring overruns). The client subtracts its delta from its gap-derived loss so
   *  a server-intentional skip stops reading as network loss. Undefined against a
   *  server that doesn't emit the 4-byte tail. */
  skippedFrames?: number;
}

/** The full ABR/codec metric snapshot the HUD overlay renders (Section 4). */
export interface StreamMetrics {
  /** live encoder params (KIND_PARAMS subtype 1), or null before first push. */
  enc: StreamEncoderParams | null;
  /** server-side per-session stats (KIND_PARAMS subtype 2), or null. */
  server: StreamServerStats | null;
  /** received video bitrate this interval (kbps). */
  recvKbps: number;
  /** decoded fps over the last report interval. */
  decodeFps: number;
  /** mean decode time per frame (ms). */
  decodeMs: number;
  /** videoDecoder.decodeQueueSize snapshot. */
  decodeQueue: number;
  /** cumulative frames dropped by the decoder. */
  framesDropped: number;
  /** cumulative freeze episodes (>250ms no paint while AUs arrive). */
  freezeCount: number;
  /** estimated loss % from frame_id gaps this interval. */
  lossPct: number;
  /** connect-time signaling `video` defaults (SIG source). */
  signal: StreamVideoParams | null;
  /** client-local `el` scores (smoothed). */
  latencyScore: number;
  lossScore: number;
  bandwidthScore: number;
  overallScore: number;
  /** local banner state. */
  banner: StreamBannerState;
  /**
   * idle-frame-stall watchdog (Section 2.2 addendum): true when NO decoded frame
   * has been painted for > FRAME_STALL_MS while the transport is still open. This
   * is DISTINCT from the RTT-ping liveness (a stalled encoder can keep the QUIC
   * link + pings perfectly healthy) and from the freeze counter (which needs AUs
   * to still be arriving). Detector only — it informs the HUD/banner, never a
   * reconnect.
   */
  stalled: boolean;
  /** cumulative VideoDecoder configure/decode errors (no longer swallowed). */
  decodeErrors: number;
  /** last decoder error message, or null if none yet. */
  lastDecodeError: string | null;
  /** active decode mode: 'avc' (avcC description + AVCC chunks — the
   *  Firefox-compatible path) or 'annexb' (bare fallback). */
  decodePath: 'avc' | 'annexb';
  /** Firefox poisoned-session rebuilds this client performed (incoming
   *  uni-stream delivery dead-on-arrival — see FF_STALL_* in streamClient). */
  sessionRebuilds: number;
}

export interface StreamClientStats {
  connected: boolean;
  lastError: string;
  framesRecv: number;
  framesDecoded: number;
  fps: number;
  guestW: number;
  guestH: number;
  /** last measured datagram round-trip (ms), or null. */
  rttMs: number | null;
  /** bytes queued on the reliable input writer (best-effort), or null. */
  sendBufferedAmount: number | null;
  audioEnabled: boolean;
}

export interface StreamClientConfig {
  /** HTTP(S) endpoint returning the signaling doc (JSON or bare base64 hash). */
  signalEndpoint: string;
  /** Called for every decoded frame. OWNERSHIP TRANSFERS: the callee closes it. */
  onVideoFrame: (frame: VideoFrame) => void;
  /** Guest resolution changed (drives letterbox math + aspect). */
  onResolution?: (w: number, h: number) => void;
  /** Connection state / error transitions. `reason` carries a structured exit
   *  discriminator on a drop (null while connecting / on connect). */
  onState?: (connected: boolean, lastError: string, reason: StreamExitReason | null) => void;
}
