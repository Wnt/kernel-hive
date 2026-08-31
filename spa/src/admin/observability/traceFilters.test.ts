// Round-tripping a filter set through a URL is the property this surface's
// linkability rests on, and it is exactly the kind of thing that breaks without
// anybody noticing: nothing throws, the link just shows a different slice than
// the one that was copied. So it is tested key by key rather than as a smoke
// test on one example.

import { describe, expect, it } from 'vitest';
import type { TraceFilters } from './types';
import {
  DEFAULT_FILTERS, DEFAULT_LIMIT, MAX_LIMIT,
  filtersToSearch, isTraceId, isUnfiltered, parseFilters, toWireFilters, windowIdFor, withWindow,
} from './traceFilters';

const roundTrip = (f: TraceFilters): TraceFilters => parseFilters(filtersToSearch(f));

describe('parseFilters', () => {
  it('drops keys it does not understand rather than carrying them', () => {
    const got = parseFilters('name=fleet.find&sql=DROP+TABLE+span&klass=probe&limit=10');
    expect(got).toEqual({ name: 'fleet.find', limit: 10 });
  });

  it('coerces the numbers, which always arrive as strings', () => {
    const got = parseFilters('sinceMs=1700000000000&minDurMs=250&offset=100');
    expect(got.sinceMs).toBe(1_700_000_000_000);
    expect(got.minDurMs).toBe(250);
    expect(got.offset).toBe(100);
  });

  it('refuses numbers that are not counts of milliseconds', () => {
    expect(parseFilters('minDurMs=abc')).toEqual({});
    expect(parseFilters('minDurMs=-5')).toEqual({});
    expect(parseFilters('minDurMs=1.5')).toEqual({});
    expect(parseFilters('sinceMs=')).toEqual({});
  });

  it('clamps limit to what the store will actually serve', () => {
    expect(parseFilters(`limit=${MAX_LIMIT * 10}`).limit).toBe(MAX_LIMIT);
    expect(parseFilters('limit=0').limit).toBe(1);
  });

  it('accepts only the enum values the server accepts', () => {
    expect(parseFilters('class=human&status=error').class).toBe('human');
    expect(parseFilters('class=robot').class).toBeUndefined();
    expect(parseFilters('status=fine').status).toBeUndefined();
  });

  it('validates free text against the server regexes, so a hand-edited URL fails visibly', () => {
    expect(parseFilters('name=fleet.find').name).toBe('fleet.find');
    expect(parseFilters('name=%27+OR+1%3D1').name).toBeUndefined();
    expect(parseFilters('session=s-01.abc').session).toBe('s-01.abc');
    expect(parseFilters(`session=${'x'.repeat(65)}`).session).toBeUndefined();
  });

  it('treats only the affirmative spelling of errorsOnly as true', () => {
    expect(parseFilters('errorsOnly=1').errorsOnly).toBe(true);
    expect(parseFilters('errorsOnly=0').errorsOnly).toBeUndefined();
    expect(parseFilters('errorsOnly=false').errorsOnly).toBeUndefined();
  });
});

describe('filtersToSearch', () => {
  it('produces a clean URL for an empty filter — a default view is not a page of empty keys', () => {
    expect(filtersToSearch({})).toBe('');
    expect(filtersToSearch({ offset: 0 })).toBe('');
  });

  it('omits a zero offset but keeps a real one', () => {
    expect(filtersToSearch({ offset: 50 })).toBe('offset=50');
  });
});

describe('round trip', () => {
  it('survives a full filter set unchanged', () => {
    const f: TraceFilters = {
      session: 'sess-42', name: 'station.connect', class: 'probe', status: 'error',
      errorsOnly: true, sinceMs: 1_700_000_000_000, untilMs: 1_700_003_600_000,
      minDurMs: 2500, limit: 200, offset: 400,
    };
    expect(roundTrip(f)).toEqual(f);
  });

  it('survives the defaults the list opens with', () => {
    expect(roundTrip(DEFAULT_FILTERS)).toEqual({ class: 'human', limit: DEFAULT_LIMIT });
  });

  it('is idempotent — parsing a URL we wrote produces the URL again', () => {
    const url = filtersToSearch({ name: 'poster.read', errorsOnly: true, minDurMs: 10 });
    expect(filtersToSearch(parseFilters(url))).toBe(url);
  });
});

describe('toWireFilters', () => {
  it('always states the page, because paging is the server’s', () => {
    expect(toWireFilters({})).toEqual({ limit: DEFAULT_LIMIT, offset: 0 });
  });

  it('is built from the whitelist, so unknown state cannot reach the query', () => {
    const sneaky = { name: 'fleet.find', order: 'dur DESC' } as unknown as TraceFilters;
    expect(toWireFilters(sneaky)).toEqual({ name: 'fleet.find', limit: DEFAULT_LIMIT, offset: 0 });
  });
});

describe('windows', () => {
  const now = 1_800_000_000_000;

  it('resolves a preset to an absolute instant, so a pasted link is the same slice', () => {
    const got = withWindow({ offset: 100 }, '1h', now);
    expect(got.sinceMs).toBe(now - 3_600_000);
    expect(got.offset).toBe(0);
  });

  it('clears the bound for "all kept"', () => {
    expect(withWindow({ sinceMs: 1 }, 'all', now).sinceMs).toBeUndefined();
  });

  it('recognises the preset a window came from, and admits when it cannot', () => {
    expect(windowIdFor({}, now)).toBe('all');
    expect(windowIdFor({ sinceMs: now - 3_600_000 }, now)).toBe('1h');
    expect(windowIdFor({ sinceMs: now - 3 * 86_400_000 }, now)).toBe('custom');
  });
});

describe('isUnfiltered / isTraceId', () => {
  it('does not count paging as a filter — a second page is the same slice', () => {
    expect(isUnfiltered({ limit: 50, offset: 50 })).toBe(true);
    expect(isUnfiltered(DEFAULT_FILTERS)).toBe(false);
  });

  it('accepts a W3C trace id and nothing else', () => {
    expect(isTraceId(' 0123456789abcdef0123456789abcdef ')).toBe(true);
    expect(isTraceId('0123456789ABCDEF0123456789ABCDEF')).toBe(false);
    expect(isTraceId('0123')).toBe(false);
  });
});
