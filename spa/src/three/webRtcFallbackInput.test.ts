// The WebRTC fallback input adapter must put BYTE-IDENTICAL records on the wire
// to the WebTransport StreamClient (it reuses streamClient/inputWire.ts), and
// route each class to the right DataChannel: moves + re-home hint on the
// unreliable `input-rel`, buttons/keys/wheel on the reliable `input`. This pins
// both — the same encoders the daemon decoder is written against, and the split.
import { describe, expect, it } from 'vitest';
import { T_MOVE_ABS, T_MOVE_REL, T_HINT, T_BUTTON, T_KEY, T_WHEEL } from './streamClient/constants';
import { WebRtcFallbackInputClient, type FallbackInputSink } from './webRtcFallbackInput';
import type { WebRtcFallbackSnapshot } from './webRtcFallbackClient';

function harness(connected = true) {
  const datagrams: Uint8Array[] = [];
  const reliable: Uint8Array[] = [];
  const snap = {
    lastError: 'x', framesReceived: 3, framesDecoded: 2, framesPerSecond: 7, rttMs: 42,
    mediaState: 'live',
  } as unknown as WebRtcFallbackSnapshot;
  let audio = true;
  const sink: FallbackInputSink = {
    writeInputDatagram: (b) => datagrams.push(b),
    writeInputReliable: (b) => reliable.push(b),
    fallbackAudioEnabled: () => audio,
    setFallbackAudioEnabled: (on) => { audio = on; },
    snapshot: () => snap,
    isInputConnected: () => connected,
  };
  return { c: new WebRtcFallbackInputClient(sink, 'win311'), datagrams, reliable, get audio() { return audio; } };
}

describe('WebRtcFallbackInputClient wire routing', () => {
  it('abs move → one input-rel datagram, type 1, x/y/cseq little-endian', () => {
    const { c, datagrams, reliable } = harness();
    c.sendMoveAbs(300, 200);
    expect(reliable).toHaveLength(0);
    expect(datagrams).toHaveLength(1);
    const b = datagrams[0]; const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
    expect(b[0]).toBe(T_MOVE_ABS);
    expect(dv.getUint16(1, true)).toBe(300);
    expect(dv.getUint16(3, true)).toBe(200);
    expect(dv.getUint32(5, true)).toBe(1); // first cseq
  });

  it('rel move and re-home hint ride input-rel', () => {
    const { c, datagrams } = harness();
    c.sendMoveRel(-5, 9);
    c.sendRehomeHint();
    expect(datagrams.map((b) => b[0])).toEqual([T_MOVE_REL, T_HINT]);
  });

  it('button, key and wheel ride the reliable input channel', () => {
    const { c, datagrams, reliable } = harness();
    c.sendMoveAbs(10, 20);       // establishes lastAbs for the button point
    c.sendButton(0, true);
    c.sendKeyScancode(0x1c, true);
    c.sendWheel(0, 3);
    expect(datagrams).toHaveLength(1); // only the move
    const types = reliable.map((b) => b[0]);
    expect(types).toEqual([T_BUTTON, T_KEY, T_WHEEL]);
  });

  it('getStats maps the media snapshot; audio toggle round-trips', () => {
    const h = harness(true);
    const s = h.c.getStats();
    expect(s.connected).toBe(true);
    expect(s.framesDecoded).toBe(2);
    expect(s.fps).toBe(7);
    expect(s.rttMs).toBe(42);
    expect(h.c.isAudioEnabled()).toBe(true);
    h.c.setAudioEnabled(false);
    expect(h.audio).toBe(false);
    expect(h.c.getMetrics()).toBeNull();
  });
});
