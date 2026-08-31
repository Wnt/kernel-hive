// Tests for the freeze detector. Every one of these guards a way this metric
// could confidently report a freeze nobody experienced — which is worse than
// not measuring freezes at all, because the number would be acted on.

import { describe, expect, it } from 'vitest';
import { DEFAULT_KEYFRAME_MS, StallWatch, stallThresholdMs } from './stallWatch';

describe('stallThresholdMs', () => {
  it('derives the threshold from the station\'s OWN heartbeat', () => {
    // Two whole missed heartbeats plus slack — one missed heartbeat is a
    // dropped GOP, which constants.ts already says is not a stall.
    expect(stallThresholdMs(2500)).toBe(6000);
    expect(stallThresholdMs(4000)).toBe(9000);
  });

  it('never drops below the repo\'s existing multi-frame-stall floor', () => {
    // A fast station could otherwise be judged frozen after a single dropped
    // frame, which is noise on every exhibit in the fleet.
    expect(stallThresholdMs(100)).toBe(2000);
    expect(stallThresholdMs(1)).toBe(2000);
  });

  it('caps a nonsense heartbeat instead of following it out of range', () => {
    expect(stallThresholdMs(10_000_000)).toBe(25_000);
  });

  it('falls back to the same default abr.ts uses when none is advertised', () => {
    const want = stallThresholdMs(DEFAULT_KEYFRAME_MS);
    expect(stallThresholdMs(null)).toBe(want);
    expect(stallThresholdMs(undefined)).toBe(want);
    expect(stallThresholdMs(0)).toBe(want);
    expect(stallThresholdMs(Number.NaN)).toBe(want);
  });

  it('sits BELOW the reconnect staleness window, so the visitor perceives the freeze first', () => {
    // abr.ts floors its "session is dead" window at 8000 ms. The gap between
    // the two is the thing worth knowing: how long somebody is asked to look
    // at a frozen machine before the software does anything about it.
    expect(stallThresholdMs(2500)).toBeLessThan(8000);
  });
});

/** A station painting a MOVING picture at `fps`, then going silent. */
function moving(w: StallWatch, from: number, frames: number, fps: number): number {
  const step = 1000 / fps;
  let t = from;
  for (let i = 0; i < frames; i += 1) {
    w.painted(t);
    t += step;
  }
  return t;
}

describe('StallWatch — the low-fps trap', () => {
  it('does NOT report a station painting only its heartbeat as frozen', () => {
    // THE trap this whole module exists for. A motionless desktop paints only
    // on the keyframe heartbeat, and several exhibits run at a couple of fps by
    // design. A fixed threshold would report all of them as permanently
    // stalled, and that signal would be a property of the exhibit, not a fault.
    const w = new StallWatch();
    w.setHeartbeat(2500);
    let t = 0;
    for (let i = 0; i < 10; i += 1) {
      w.painted(t);
      // Poll all the way through the heartbeat gap; nothing may fire.
      for (let s = 0; s < 2500; s += 500) expect(w.tick(t + s)).toBeNull();
      t += 2500;
    }
    expect(w.stalled()).toBe(false);
  });

  it('does not report a freeze on an IDLE station even past the threshold', () => {
    // A gap on a motionless desktop is not perceptible: the picture looks
    // identical whether frames are arriving or not, so counting it would be
    // measuring something nobody experienced.
    const w = new StallWatch();
    w.setHeartbeat(2500);
    w.painted(0);
    w.painted(2500); // heartbeat cadence only — no motion
    expect(w.tick(20_000)).toBeNull();
    expect(w.stalled()).toBe(false);
  });

  it('scales the threshold so a 2 fps station is judged on its own cadence', () => {
    const w = new StallWatch();
    w.setHeartbeat(500); // a fast heartbeat: gaps are meaningful sooner
    expect(w.thresholdMs()).toBe(2000);
  });
});

describe('StallWatch — a freeze the visitor can actually see', () => {
  it('reports a freeze when a MOVING picture stops', () => {
    const w = new StallWatch();
    w.setHeartbeat(2500);
    const t = moving(w, 0, 30, 30); // real animation, well under the heartbeat
    expect(w.tick(t + 1000)).toBeNull();      // inside the threshold
    expect(w.tick(t + 6001)).toBe('begin');   // past it
    expect(w.stalled()).toBe(true);
  });

  it('reports a freeze on an idle station once the visitor ASKS it to move', () => {
    // The second half of the perceptibility rule: a visitor who clicked and
    // saw nothing happen is waiting on a reaction, whether or not the desktop
    // was animating before.
    const w = new StallWatch();
    w.setHeartbeat(2500);
    w.painted(0);
    w.painted(2500);
    w.input(2600); // after the last paint
    expect(w.tick(9000)).toBe('begin');
  });

  it('ignores input that landed BEFORE the last paint', () => {
    // That click was already answered — the picture moved after it.
    const w = new StallWatch();
    w.setHeartbeat(2500);
    w.painted(0);
    w.input(100);
    w.painted(2500);
    expect(w.tick(9000)).toBeNull();
  });

  it('ends the freeze on a PAINT, never on the passage of time', () => {
    const w = new StallWatch();
    w.setHeartbeat(2500);
    const t = moving(w, 0, 30, 30);
    expect(w.tick(t + 6001)).toBe('begin');
    expect(w.tick(t + 30_000)).toBeNull(); // still frozen, however long we wait
    w.painted(t + 30_100);
    expect(w.tick(t + 30_100)).toBe('end');
    expect(w.stalled()).toBe(false);
  });

  it('reports begin and end exactly once per episode', () => {
    const w = new StallWatch();
    w.setHeartbeat(2500);
    const t = moving(w, 0, 30, 30);
    expect(w.tick(t + 6001)).toBe('begin');
    expect(w.tick(t + 6500)).toBeNull();
    expect(w.tick(t + 7000)).toBeNull();
    w.painted(t + 7100);
    expect(w.tick(t + 7100)).toBe('end');
    expect(w.tick(t + 7200)).toBeNull();
  });

  it('says nothing at all about a session that never painted', () => {
    // Never getting a first frame is `station.connect`'s funnel, not a freeze.
    const w = new StallWatch();
    w.setHeartbeat(2500);
    expect(w.tick(60_000)).toBeNull();
    expect(w.stalled()).toBe(false);
  });

  it('can freeze again after recovering', () => {
    const w = new StallWatch();
    w.setHeartbeat(2500);
    let t = moving(w, 0, 30, 30);
    expect(w.tick(t + 6001)).toBe('begin');
    t = moving(w, t + 7000, 30, 30);
    expect(w.tick(t)).toBe('end');
    expect(w.tick(t + 6001)).toBe('begin');
  });
});
