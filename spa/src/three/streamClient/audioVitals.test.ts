import { describe, expect, it } from 'vitest';
import { AudioPlayer } from './audioPlayer';

/**
 * The continuous audio vitals, driven through the REAL `play()` path rather
 * than by poking private fields — the underrun counter lives inside an
 * existing branch of that method, and a test that reached around it would not
 * have caught the defect it exists to pin.
 */
function fakeCtx(startTime = 5) {
  let now = startTime;
  return {
    ctx: {
      state: 'running' as AudioContextState,
      get currentTime() { return now; },
      createGain: () => ({ gain: { value: 0 }, connect() {}, disconnect() {} }),
      createBuffer: (_c: number, frames: number, rate: number) => ({
        duration: frames / rate, copyToChannel() {},
      }),
      createBufferSource: () => ({ buffer: null as unknown, connect() {}, start() {} }),
      destination: {},
      close: async () => {},
    },
    advance(by: number) { now += by; },
  };
}

function audioData(frames = 960, ts = 1_000_000) {
  return {
    numberOfChannels: 1, numberOfFrames: frames, sampleRate: 48_000, timestamp: ts,
    copyTo() {}, close() {},
  };
}

function playerOn(ctx: unknown) {
  const p = new AudioPlayer(() => {});
  // The context and gain are created lazily by setupDecoder(); inject the
  // fake so `play()` runs its real body.
  (p as unknown as Record<string, unknown>).audioCtx = ctx;
  (p as unknown as Record<string, unknown>).audioGain = { gain: { value: 1 }, connect() {}, disconnect() {} };
  p.setEnabled(true);
  return p;
}

describe('AudioPlayer continuous vitals', () => {
  it('reports nothing at all when there is no audio path', () => {
    expect(new AudioPlayer(() => {}).vitals()).toBeNull();
  });

  it('does NOT count the first packet as an underrun', () => {
    // THE REGRESSION. `playHead` starts at 0 and `currentTime` does not, so the
    // first play() always takes the anti-underrun clamp. Measured live on
    // 2026-09-01: every session reported exactly 1 underrun, which would make
    // any threshold on this metric fire on every visitor.
    const { ctx } = fakeCtx(5);
    const p = playerOn(ctx);
    (p as unknown as { play(d: unknown): void }).play(audioData());
    expect(p.vitals()?.underruns).toBe(0);
    expect(p.vitals()?.frames).toBe(960);
  });

  it('counts a genuine underrun — the play head overtaken by the clock', () => {
    const f = fakeCtx(5);
    const p = playerOn(f.ctx);
    const play = (p as unknown as { play(d: unknown): void }).play.bind(p);
    play(audioData());                 // initialises the head; not an underrun
    play(audioData());                 // still ahead of the clock
    expect(p.vitals()?.underruns).toBe(0);
    f.advance(30);                     // the stream ran dry for 30 seconds
    play(audioData());
    expect(p.vitals()?.underruns).toBe(1);
  });

  it('reports the play-head lead — the queue depth an underrun threshold precedes', () => {
    const f = fakeCtx(5);
    const p = playerOn(f.ctx);
    const play = (p as unknown as { play(d: unknown): void }).play.bind(p);
    play(audioData(48_000));           // one second of audio
    const v = p.vitals();
    expect(v?.running).toBe(1);
    expect(v!.leadMs).toBeGreaterThan(900);
  });

  it('keeps the last capture stamp — the A/V skew operand', () => {
    const f = fakeCtx(5);
    const p = playerOn(f.ctx);
    (p as unknown as { play(d: unknown): void }).play(audioData(960, 4_242_424));
    expect(p.vitals()?.tsUs).toBe(4_242_424);
  });
});
