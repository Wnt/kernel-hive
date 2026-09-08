// The client-path selection matrix. Safari 17 (VideoDecoder, no WebTransport)
// was sent down the WebTransport path and could never connect — the rule is
// "both APIs or the fallback", and this pins every cell of it.
import { describe, it, expect, afterEach } from 'vitest';
import { selectClientTransport, usesWebRtcFallback, detectCaps } from './streamTransportSelect';

const g = globalThis as { WebTransport?: unknown; VideoDecoder?: unknown };

afterEach(() => { delete g.WebTransport; delete g.VideoDecoder; });

describe('selectClientTransport', () => {
  it('WebTransport + VideoDecoder → webtransport (Chrome, desktop Firefox)', () => {
    expect(selectClientTransport({ wt: true, vd: true })).toBe('webtransport');
  });
  it('no WebTransport → WebRTC fallback (Safari 17: VideoDecoder present)', () => {
    expect(selectClientTransport({ wt: false, vd: true })).toBe('webrtc-fallback');
  });
  it('no VideoDecoder → WebRTC fallback (Firefox-Android: WebTransport present)', () => {
    expect(selectClientTransport({ wt: true, vd: false })).toBe('webrtc-fallback');
  });
  it('neither → WebRTC fallback, not an error', () => {
    expect(selectClientTransport({ wt: false, vd: false })).toBe('webrtc-fallback');
    expect(usesWebRtcFallback({ wt: false, vd: false })).toBe(true);
  });
  it('reads the live globals when not told', () => {
    expect(detectCaps()).toEqual({ wt: false, vd: false });
    g.WebTransport = class {};
    g.VideoDecoder = class {};
    expect(detectCaps()).toEqual({ wt: true, vd: true });
    expect(selectClientTransport()).toBe('webtransport');
    delete g.WebTransport; // Safari 17 shape
    expect(selectClientTransport()).toBe('webrtc-fallback');
  });
});
