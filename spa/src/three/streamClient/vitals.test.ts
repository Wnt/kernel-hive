import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { beginVitals, dueForVitals, endVitals, flushVitals, recordVitals, skewMs } from './vitals';

describe('skewMs — the u32 capture-clock wrap', () => {
  it('is a plain difference away from the wrap', () => {
    expect(skewMs(1_050_000, 1_000_000)).toBeCloseTo(50);
    expect(skewMs(1_000_000, 1_050_000)).toBeCloseTo(-50);
  });

  it('reads a wrap as a small skew, not as 71 minutes', () => {
    // Audio has just wrapped past 2^32; video has not. A naive subtraction
    // would report -4,294.9 SECONDS of skew and put an impossible spike on
    // every chart once every 71.6 minutes.
    const video = 0xffff_ff00; // just under the wrap
    const audio = 0x0000_0064; // 100 µs after it — a true skew of +356 µs
    expect(skewMs(audio, video)).toBeCloseTo(0.356, 3);
    expect(skewMs(video, audio)).toBeCloseTo(-0.356, 3);
  });
});

describe('the vitals sink', () => {
  let posts: Array<{ url: string; body: unknown }>;

  beforeEach(() => {
    posts = [];
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: { body: string }) => {
      posts.push({ url, body: JSON.parse(init.body) });
      return { ok: true, status: 200 } as Response;
    }));
  });
  afterEach(() => { endVitals(); vi.unstubAllGlobals(); });

  it('samples at 1 Hz, on its own clock and not the ABR tick or the log line', () => {
    beginVitals('macos753', 'b1');
    // The ABR tick runs at ~100 ms. Only one in ten may take a sample, or the
    // series would carry ten identical daemon-side rows a second.
    expect(dueForVitals(1000)).toBe(true);
    expect(dueForVitals(1100)).toBe(false);
    expect(dueForVitals(1900)).toBe(false);
    expect(dueForVitals(2000)).toBe(true);
    // And 1 s is genuinely finer than the 5 s log line: four samples land
    // inside one of its intervals, which is what makes a downshift and the
    // recovery from it two visible points rather than none.
    expect([2500, 3000, 4000, 5000, 6000].filter((t) => dueForVitals(t))).toEqual([3000, 4000, 5000, 6000]);
  });

  it('starts a new station sampling immediately rather than a second late', () => {
    beginVitals('a', 'b1');
    expect(dueForVitals(50_000)).toBe(true);
    beginVitals('b', 'b1');
    expect(dueForVitals(50_001)).toBe(true);
  });

  it('is due for nothing before a producer is named', () => {
    endVitals();
    expect(dueForVitals(999_999)).toBe(false);
  });

  it('sends nothing until a producer is named', async () => {
    recordVitals({ fps: 30 });
    await flushVitals();
    expect(posts).toHaveLength(0);
  });

  it('puts the station in service.instance.id — the field that makes an entity', async () => {
    beginVitals('win311', 'b-42');
    recordVitals({ fps: 30, rtt_ms: 11.5 });
    await flushVitals();
    expect(posts).toHaveLength(1);
    const body = posts[0].body as { resource: Record<string, string>; samples: unknown[] };
    expect(posts[0].url).toBe('/vitals');
    expect(body.resource['service.instance.id']).toBe('win311');
    expect(body.resource['kh.bundle']).toBe('b-42');
    expect(body.resource['kh.source']).toBe('spa');
    expect(body.samples).toHaveLength(1);
  });

  it('drops non-finite values rather than the sample carrying them', async () => {
    beginVitals('beos', 'b1');
    recordVitals({ fps: 30, rtt_ms: Number.NaN, decode_ms: Number.POSITIVE_INFINITY });
    await flushVitals();
    const s = (posts[0].body as { samples: Array<{ v: Record<string, number> }> }).samples[0];
    expect(s.v).toEqual({ fps: 30 });
  });

  it('sends nothing at all for a sample with no finite value in it', async () => {
    beginVitals('beos', 'b1');
    recordVitals({ fps: Number.NaN });
    await flushVitals();
    expect(posts).toHaveLength(0);
  });

  it('folds a network failure back into the queue — the worst sessions are the ones that fail to report', async () => {
    beginVitals('irix', 'b1');
    recordVitals({ fps: 12 });
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline'); }));
    await flushVitals();
    // Re-armed: the next flush, once the network is back, still carries it.
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: { body: string }) => {
      posts.push({ url, body: JSON.parse(init.body) });
      return { ok: true, status: 200 } as Response;
    }));
    await flushVitals();
    expect(posts).toHaveLength(1);
    expect((posts[0].body as { samples: Array<{ v: Record<string, number> }> }).samples[0].v).toEqual({ fps: 12 });
  });

  it('drops on a 4xx rather than re-offering a body the server has judged', async () => {
    beginVitals('irix', 'b1');
    recordVitals({ fps: 12 });
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 400 } as Response)));
    await flushVitals();
    vi.stubGlobal('fetch', vi.fn(async (url: string, init: { body: string }) => {
      posts.push({ url, body: JSON.parse(init.body) });
      return { ok: true, status: 200 } as Response;
    }));
    await flushVitals();
    expect(posts).toHaveLength(0);
  });
});
