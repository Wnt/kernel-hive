// ============================================================================
//  three/streamTransportSelect — WHICH CLIENT PATH THIS BROWSER GETS.
//  ---------------------------------------------------------------------------
//  Two paths exist (docs/WEBRTC-PLATFORM.md): WebTransport + WebCodecs is the
//  primary, and native WebRTC is the fallback. The selection used to ask ONE
//  question — "is VideoDecoder defined?" — because the fallback was built for
//  Firefox-Android, where WebTransport exists and the decoder does not. The
//  converse browser was never asked about: Safari 17 (macOS/iPadOS,
//  `Version/17.x Safari/605.1.15`) HAS VideoDecoder and has NO WebTransport,
//  so it was sent down the primary path and burned four attempts on
//  `ReferenceError: Can't find variable: WebTransport` (clientlog session
//  d5af8bdf, 2026-09-08, a walk-in on win311), then fell to the poster.
//
//  The primary path needs BOTH APIs; the fallback needs neither. So the rule
//  is: WebTransport AND VideoDecoder → webtransport; anything else → WebRTC
//  fallback (a browser with neither goes to WebRTC too — it can still play a
//  MediaStream). Feature detection, deliberately not a UA check. Every site
//  that used to test `typeof VideoDecoder` alone now asks here, so the four
//  callers cannot drift apart again.
// ============================================================================

export type ClientTransport = 'webtransport' | 'webrtc-fallback';

export interface TransportCaps {
  wt: boolean;
  vd: boolean;
}

/** What THIS browser exposes. Read fresh each call: cheap, and a test can
 *  define/undefine the globals between calls. */
export function detectCaps(): TransportCaps {
  return {
    wt: typeof WebTransport !== 'undefined',
    vd: typeof VideoDecoder !== 'undefined',
  };
}

/** The selection matrix. Pure, so the test can enumerate it. */
export function selectClientTransport(caps: TransportCaps = detectCaps()): ClientTransport {
  return caps.wt && caps.vd ? 'webtransport' : 'webrtc-fallback';
}

/** True when this browser takes the native WebRTC fallback. */
export function usesWebRtcFallback(caps?: TransportCaps): boolean {
  return selectClientTransport(caps) === 'webrtc-fallback';
}
