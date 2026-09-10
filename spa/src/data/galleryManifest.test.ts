// Unit coverage for the runtime gallery-manifest loader/validator. The lineup
// is fetched, never bundled, so the contract under test is: a valid runtime
// document wins, and every failure (HTTP, schema, network) returns an EMPTY
// lineup without throwing and without logging — nothing stale substituted in,
// and no console.error either, on purpose: this function cannot tell an
// expected refusal (an anonymous visitor's manifest fetch, always 401 on the
// public listener) from a genuine break, and useManifest.ts is where that
// outcome is actually known and where the loud log now lives.
// Mirrors scripts/test-gallery-manifest.mjs (kept as the framework-free
// `npm run test:manifest` sibling check against the rendered document).
import { describe, expect, it, vi } from 'vitest';
import { loadGalleryManifest, validateGalleryManifest } from './galleryManifest';

const validEntry = {
  id: 'c64',
  era_year: 1982,
  displayName: 'Commodore 64',
  year: 1982,
  lineage: 'Commodore 64',
  arch: 'MOS 6510',
  accent: '#6c5eb5',
  archetypeId: 'beige-tower-crt',
  transport: 'streamhost',
  order: 0,
  eraLabel: '1982 · C64 + GEOS',
  signalEndpoint: '/signal/c64.json',
  notes: '',
  era: '1980s',
  eraSoftware: [],
  periodBrowser: 'none',
  iconicApps: [],
  blurb: 'blurb',
};

function doc(entries: unknown[]) {
  return { schemaVersion: 1, entries };
}

describe('validateGalleryManifest', () => {
  it('accepts a well-formed document and sorts by order', () => {
    const result = validateGalleryManifest(
      doc([
        { ...validEntry, id: 'b', order: 1 },
        { ...validEntry, id: 'a', order: 0 },
      ]),
    );
    expect(result).not.toBeNull();
    expect(result?.entries.map((e) => e.id)).toEqual(['a', 'b']);
  });

  it('rejects non-object / wrong schemaVersion / empty entries', () => {
    expect(validateGalleryManifest(null)).toBeNull();
    expect(validateGalleryManifest('nope')).toBeNull();
    expect(validateGalleryManifest({ schemaVersion: 2, entries: [validEntry] })).toBeNull();
    expect(validateGalleryManifest(doc([]))).toBeNull();
  });

  it('rejects an unknown top-level field (no silent extra data)', () => {
    expect(validateGalleryManifest({ ...doc([validEntry]), password: 'nope' })).toBeNull();
  });

  it('rejects duplicate ids and duplicate order values', () => {
    expect(validateGalleryManifest(doc([validEntry, { ...validEntry }]))).toBeNull();
    expect(
      validateGalleryManifest(doc([validEntry, { ...validEntry, id: 'other' }])),
    ).toBeNull();
  });

  it('rejects an entry with an unknown field, bad accent, or bad archetype/transport', () => {
    expect(validateGalleryManifest(doc([{ ...validEntry, extra: 1 }]))).toBeNull();
    expect(validateGalleryManifest(doc([{ ...validEntry, accent: 'red' }]))).toBeNull();
    expect(validateGalleryManifest(doc([{ ...validEntry, archetypeId: 'nope' }]))).toBeNull();
    expect(validateGalleryManifest(doc([{ ...validEntry, transport: 'nope' }]))).toBeNull();
  });

  it('requires eraLabel to start with "<year> · "', () => {
    expect(validateGalleryManifest(doc([{ ...validEntry, eraLabel: 'wrong' }]))).toBeNull();
  });

  it('requires a signalEndpoint under /signal/ for streamhost, forbids one for showcase', () => {
    expect(
      validateGalleryManifest(doc([{ ...validEntry, signalEndpoint: '/other/c64.json' }])),
    ).toBeNull();
    expect(
      validateGalleryManifest(
        doc([{ ...validEntry, transport: 'showcase', signalEndpoint: '/signal/c64.json' }]),
      ),
    ).toBeNull();
    expect(
      validateGalleryManifest(doc([{ ...validEntry, transport: 'showcase', signalEndpoint: undefined }]))?.entries.length,
    ).toBe(1);
  });

  it('maps a string bootVideo into { mp4 }', () => {
    const result = validateGalleryManifest(doc([{ ...validEntry, bootVideo: 'boot/c64.mp4' }]));
    expect(result?.entries[0].bootVideo).toEqual({ mp4: 'boot/c64.mp4' });
  });
});

describe('loadGalleryManifest', () => {
  it('prefers the runtime-fetched manifest on a 200 + valid body', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify(doc([{ ...validEntry, id: 'fetched' }])), { status: 200 }));
    const rows = await loadGalleryManifest(fetcher);
    expect(rows.map((r) => r.id)).toEqual(['fetched']);
    expect(fetcher).toHaveBeenCalledWith('/gallery-manifest.json', { cache: 'no-cache' });
  });

  it('returns an empty lineup on HTTP failure, without logging (no throw)', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const rows = await loadGalleryManifest(async () => new Response('nope', { status: 404 }));
    expect(rows).toEqual([]);
    // NOT logged here — an HTTP failure is exactly what an anonymous
    // visitor's request produces on the public listener, every time, and
    // useManifest.ts recovers it through the walk-in projection. Logging at
    // this level reported that recovery as a red console.error on every
    // anonymous landing.
    expect(error).not.toHaveBeenCalled();
    error.mockRestore();
  });

  it('returns an empty lineup on invalid schema, without logging (no throw)', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const rows = await loadGalleryManifest(async () => new Response(JSON.stringify({ nope: true }), { status: 200 }));
    expect(rows).toEqual([]);
    expect(error).not.toHaveBeenCalled();
    error.mockRestore();
  });

  it('returns an empty lineup when the fetch itself rejects, without logging', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const rows = await loadGalleryManifest(async () => {
      throw new Error('network down');
    });
    expect(rows).toEqual([]);
    expect(error).not.toHaveBeenCalled();
    error.mockRestore();
  });
});
