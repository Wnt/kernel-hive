// The paused-sink bug, pinned. The trap these guard: a healthy transport whose
// <video> stopped pulling looks EXACTLY like a dead stream from the outside —
// black picture, fps 0 — and the two want opposite responses.
import { describe, expect, it, vi } from 'vitest';
import {
  isPausedSink,
  liveEdgeSeekTarget,
  probeVideoSink,
  resumeVideoElement,
  LIVE_EDGE_MAX_LAG_S,
  type VideoSinkProbe,
} from './videoResume';

const probe = (over: Partial<VideoSinkProbe> = {}): VideoSinkProbe => ({
  hasSource: true, paused: true, readyState: 4, width: 1024, currentTime: 6.78, error: null,
  ...over,
});

/** The operator's element: MediaStream-backed, so `seekable` is empty. */
type FakeVideo = {
  srcObject: unknown; currentSrc: string; src: string;
  paused: boolean; readyState: number; videoWidth: number; currentTime: number; error: unknown;
  seekable: { length: number; end(i: number): number };
  play: ReturnType<typeof vi.fn>;
};

const fakeVideo = (over: Record<string, unknown> = {}) => {
  const el: FakeVideo = {
    srcObject: {}, currentSrc: '', src: '',
    paused: true, readyState: 4, videoWidth: 1024, currentTime: 6.78, error: null,
    seekable: { length: 0, end: () => 0 },
    play: vi.fn(async () => {
      el.paused = false;
      // A MediaStream element resumes at the live edge by construction.
      el.currentTime = 662.24;
    }),
    ...over,
  };
  return el;
};

/** The fakes are structural; the module only ever reads these fields. */
const asEl = (v: FakeVideo) => v as unknown as HTMLVideoElement;

describe('isPausedSink — nothing arriving vs nothing consuming', () => {
  it('names the field signature: paused, visible, readyState 4, no error', () => {
    expect(isPausedSink(probe(), true)).toBe(true);
  });

  it('is NOT a paused sink while the page is hidden — pausing there is correct', () => {
    expect(isPausedSink(probe(), false)).toBe(false);
  });

  it('is NOT a paused sink when the element is playing (a real no-data stall)', () => {
    expect(isPausedSink(probe({ paused: false }), true)).toBe(false);
  });

  it('is NOT a paused sink when the element carries an error (decoder fault)', () => {
    expect(isPausedSink(probe({ error: { code: 3 } }), true)).toBe(false);
  });

  it('is NOT a paused sink before a source is attached', () => {
    expect(isPausedSink(probe({ hasSource: false }), true)).toBe(false);
  });

  it('has nothing to say about a missing element', () => {
    expect(isPausedSink(null, true)).toBe(false);
  });
});

describe('probeVideoSink', () => {
  it('reads the element without throwing on a torn-down one', () => {
    const dead = { get paused(): boolean { throw new Error('gone'); } } as unknown as HTMLVideoElement;
    expect(probeVideoSink(dead)).toBeNull();
    expect(probeVideoSink(null)).toBeNull();
  });

  it('reports a MediaStream element as sourced', () => {
    expect(probeVideoSink(asEl(fakeVideo()))?.hasSource).toBe(true);
  });
});

describe('liveEdgeSeekTarget — show NOW, never the backlog', () => {
  it('has no seek to offer on a live MediaStream (empty seekable)', () => {
    expect(liveEdgeSeekTarget({ currentTime: 6.78, seekable: { length: 0, end: () => 0 } })).toBeNull();
  });

  it('returns the last seekable instant when the clock is behind it', () => {
    expect(liveEdgeSeekTarget({ currentTime: 6.78, seekable: { length: 1, end: () => 662.24 } }))
      .toBeCloseTo(662.24);
  });

  it('does not seek when already at the edge within tolerance', () => {
    const seekable = { length: 1, end: () => 100 };
    expect(liveEdgeSeekTarget({ currentTime: 100 - LIVE_EDGE_MAX_LAG_S / 2, seekable })).toBeNull();
  });

  it('ignores an infinite edge rather than assigning Infinity to currentTime', () => {
    expect(liveEdgeSeekTarget({ currentTime: 0, seekable: { length: 1, end: () => Infinity } })).toBeNull();
  });
});

describe('resumeVideoElement', () => {
  it('resumes a paused sink and reports the jump to the live edge', async () => {
    const el = fakeVideo();
    const r = await resumeVideoElement(asEl(el), true);
    expect(el.play).toHaveBeenCalled();
    expect(r.outcome).toBe('resumed');
    expect(r.advanced).toBeCloseTo(655.46, 1); // the operator's measured jump
  });

  it('leaves a hidden page paused — never wakes a backgrounded exhibit', async () => {
    const el = fakeVideo();
    expect((await resumeVideoElement(asEl(el), false)).outcome).toBe('hidden');
    expect(el.play).not.toHaveBeenCalled();
  });

  it('does not touch an element that is already playing', async () => {
    const el = fakeVideo({ paused: false });
    expect((await resumeVideoElement(asEl(el), true)).outcome).toBe('playing');
    expect(el.play).not.toHaveBeenCalled();
  });

  it('reports no-sink for an element with nothing attached', async () => {
    const el = fakeVideo({ srcObject: null, currentSrc: '', src: '' });
    expect((await resumeVideoElement(asEl(el), true)).outcome).toBe('no-sink');
  });

  it('surfaces an autoplay rejection as `blocked`, never as a silent black screen', async () => {
    const el = fakeVideo({
      play: vi.fn(async () => { throw Object.assign(new Error('gesture'), { name: 'NotAllowedError' }); }),
    });
    const r = await resumeVideoElement(asEl(el), true);
    expect(r.outcome).toBe('blocked');
    expect(r.error).toBe('NotAllowedError');
  });

  it('seeks a BUFFERED source to the edge before playing — no backlog playout', async () => {
    const sets: number[] = [];
    const el = fakeVideo({
      srcObject: null, src: 'blob:x', currentSrc: 'blob:x',
      seekable: { length: 1, end: () => 662.24 },
      play: vi.fn(async () => { el.paused = false; }),
    });
    Object.defineProperty(el, 'currentTime', {
      get: () => sets.length ? sets[sets.length - 1] : 6.78,
      set: (v: number) => { sets.push(v); },
    });
    const r = await resumeVideoElement(asEl(el), true);
    expect(r.outcome).toBe('resumed');
    expect(r.seeked).toBe(true);
    expect(sets[0]).toBeCloseTo(662.24); // sought BEFORE play, not after
  });
});
