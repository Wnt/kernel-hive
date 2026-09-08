// ============================================================================
//  streamInputClient — the client contract `createStreamController` depends on.
//  ---------------------------------------------------------------------------
//  The controller (useStreamControl) was written against the concrete
//  `StreamClient` (the WebTransport path). But its needs are a narrow slice of
//  that class: the browser→daemon INPUT send surface plus a handful of read-only
//  HUD/liveness getters. Naming that slice as an interface lets a SECOND
//  transport — the native-decoder WebRTC fallback (`webRtcFallbackClient.ts`,
//  which used to carry VIDEO ONLY) — present the same surface and drive the
//  exact same controller, so `useStreamControl`, `OnScreenKeyboard` and
//  `keySender` need no per-transport branch (they only ever see the
//  `StreamControlHandle` the controller returns).
//
//  `StreamClient` satisfies this structurally and is unchanged; the fallback's
//  `WebRtcFallbackInputClient` implements it over two WebRTC DataChannels.
// ============================================================================

import type {
  StreamBannerState,
  StreamExitReason,
  StreamMetrics,
  StreamClientStats,
} from './streamClient/types';

/** The subset of `StreamClient` that `createStreamController` consumes. Both
 *  the WebTransport `StreamClient` and the WebRTC `WebRtcFallbackInputClient`
 *  implement it, so the controller is transport-agnostic. */
export interface StreamInputClient {
  // ---- browser→daemon input send surface (encoders in streamClient/inputWire)
  sendMoveAbs(x: number, y: number): void;
  sendMoveRel(dx: number, dy: number): void;
  sendRehomeHint(): void;
  moveWireSnapshot(): { sent: number; rejected: number; desiredSizeMin: number | null };
  sendButton(button: number, down: boolean, x?: number, y?: number): void;
  sendKeyScancode(keycode: number, down: boolean): void;
  sendWheel(dx: number, dy: number): void;

  // ---- read-only HUD / liveness / control-plane getters --------------------
  getBannerState(): StreamBannerState;
  getExitReason(): StreamExitReason | null;
  getFrameStalled(): boolean;
  getLastDecodeError(): string | null;
  /** The HUD metric snapshot, or null when a transport keeps none (the WebRTC
   *  fallback: its native `getStats()` overlay is surfaced separately). */
  getMetrics(): StreamMetrics | null;
  getStats(): StreamClientStats;
  isConnected(): boolean;

  // ---- audio (streamhost audio-always-on) ----------------------------------
  isAudioEnabled(): boolean;
  setAudioEnabled(on: boolean): void;

  // ---- ABR report tick (a no-op where there is no ABR feedback wire) --------
  tickStats(): void;
}
