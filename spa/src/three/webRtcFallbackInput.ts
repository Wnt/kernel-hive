// ============================================================================
//  webRtcFallbackInput — the WebRTC fallback's browser→daemon INPUT client.
//  ---------------------------------------------------------------------------
//  The native-decoder fallback (`webRtcFallbackClient.ts`) used to carry VIDEO
//  ONLY: a Safari-17 / Firefox-Android visitor could watch a station but not
//  touch it. This adapter gives that path the SAME input surface the
//  WebTransport `StreamClient` has, so `createStreamController` (useStreamControl)
//  drives it with no per-transport branch.
//
//  It reuses the EXISTING wire encoders (`streamClient/inputWire.ts`) verbatim —
//  the records are byte-identical to the WebTransport path, so the daemon
//  decoder is shared, not forked. Only the carrier differs: instead of QUIC
//  datagrams + per-class reliable uni-streams it writes two WebRTC DataChannels
//  the fallback PeerConnection opens (`input-rel` unreliable for moves,
//  `input` reliable for buttons/keys/wheel — see webRtcFallbackClient.ts).
// ============================================================================

import type { StreamClientLike } from './streamClient/inputWire';
import {
  moveWireSnapshotImpl, noteMoveWireImpl, sendButtonImpl, sendKeyScancodeImpl,
  sendMoveAbsImpl, sendMoveRelImpl, sendRehomeHintImpl, sendWheelImpl,
} from './streamClient/inputWire';
import type { StreamInputClient } from './streamInputClient';
import type {
  StreamBannerState, StreamExitReason, StreamMetrics, StreamClientStats,
} from './streamClient/types';
import type { WebRtcFallbackSnapshot } from './webRtcFallbackClient';

/** What the adapter needs from the fallback client — the two DataChannel
 *  writers, the audio toggle, and the live snapshot. A narrow interface (not
 *  the client itself) so the value import stays one-directional
 *  (client → adapter) and this module carries only types of the client. */
export interface FallbackInputSink {
  /** Write one raw input record on the unreliable `input-rel` channel (moves +
   *  re-home hint). No-op until that channel is open. */
  writeInputDatagram(b: Uint8Array): void;
  /** Write one raw input record on the reliable `input` channel (buttons, keys,
   *  wheel). No-op until the channel is open AND the ticket has been sent. */
  writeInputReliable(b: Uint8Array): void;
  fallbackAudioEnabled(): boolean;
  setFallbackAudioEnabled(on: boolean): void;
  snapshot(): WebRtcFallbackSnapshot;
  isInputConnected(): boolean;
}

export class WebRtcFallbackInputClient implements StreamClientLike, StreamInputClient {
  // ---- StreamClientLike wire state (mutated by the shared inputWire impls) --
  cseq = 0;
  stationId: string | null;
  lastAbsX: number | null = null;
  lastAbsY: number | null = null;
  moveSent = 0;
  moveRejected = 0;
  moveDesiredMin = Infinity;
  dgWriter: WritableStreamDefaultWriter<Uint8Array> | null = null;

  private sink: FallbackInputSink;

  constructor(sink: FallbackInputSink, stationId: string | null) {
    this.sink = sink;
    this.stationId = stationId;
  }

  // ---- carrier: the two DataChannels replace datagrams + reliable uni-streams
  writeDatagram(b: Uint8Array) { this.sink.writeInputDatagram(b); }
  // The class tag selects a per-type QUIC stream on WebTransport; a DataChannel
  // message is already a boundary and the record is self-describing (rec[0] is
  // the type), so the reliable channel carries every class and the tag is dropped.
  writeReliableClass(_cls: number, rec: Uint8Array) { this.sink.writeInputReliable(rec); }
  noteMoveWire() { noteMoveWireImpl(this); }
  nextCseq(): number { this.cseq = (this.cseq + 1) >>> 0; return this.cseq; }

  // ---- input send surface (identical encoders to StreamClient) -------------
  sendMoveAbs(x: number, y: number) { sendMoveAbsImpl(this, x, y); }
  sendMoveRel(dx: number, dy: number) { sendMoveRelImpl(this, dx, dy); }
  sendRehomeHint() { sendRehomeHintImpl(this); }
  moveWireSnapshot() { return moveWireSnapshotImpl(this); }
  sendButton(button: number, down: boolean, x?: number, y?: number) {
    sendButtonImpl(this, button, down, x, y);
  }
  sendKeyScancode(keycode: number, down: boolean) { sendKeyScancodeImpl(this, keycode, down); }
  sendWheel(dx: number, dy: number) { sendWheelImpl(this, dx, dy); }

  // ---- read-only HUD / liveness getters, mapped from the media snapshot -----
  //  The fallback has no ABR feedback wire, no server-authoritative banner and
  //  no per-frame decode-error stream, so these report the neutral values the
  //  HUD renders as "healthy". The media health is surfaced through the
  //  session's own `WebRtcFallbackSnapshot` (useStreamhostSession), not here.
  getBannerState(): StreamBannerState { return 'good'; }
  getExitReason(): StreamExitReason | null { return null; }
  getFrameStalled(): boolean { return this.sink.snapshot().mediaState === 'stalled'; }
  getLastDecodeError(): string | null { return null; }
  getMetrics(): StreamMetrics | null { return null; }
  getStats(): StreamClientStats {
    const s = this.sink.snapshot();
    return {
      connected: this.sink.isInputConnected(),
      lastError: s.lastError,
      framesRecv: s.framesReceived,
      framesDecoded: s.framesDecoded,
      fps: s.framesPerSecond,
      guestW: 0,
      guestH: 0,
      rttMs: s.rttMs || null,
      sendBufferedAmount: null,
      audioEnabled: this.sink.fallbackAudioEnabled(),
    };
  }
  isConnected(): boolean { return this.sink.isInputConnected(); }

  // ---- audio (owned by the fallback client's own <audio> element) ----------
  isAudioEnabled(): boolean { return this.sink.fallbackAudioEnabled(); }
  setAudioEnabled(on: boolean) { this.sink.setFallbackAudioEnabled(on); }

  // ---- ABR tick: no feedback wire on the fallback, so nothing to report -----
  tickStats(): void { /* no ABR report datagram on the WebRTC fallback */ }
}
