// The grid filter is judged entirely by what it returns for a handful of things
// a visitor actually types, so this suite runs against the REAL rendered
// lineup (lineupFixture) rather than a hand-made row: a fixture would let the
// matcher stay green while the collection it filters drifts underneath it.
//
// Both halves matter. The positive cases are the shorthands the filter exists
// to serve; the negative ones are the failure mode that makes a filter feel
// broken — a short or numeric query that lights up the whole page.
import { describe, expect, it } from 'vitest';
import { renderedEntries } from '../../data/lineupFixture';
import {
  aliasKey,
  matchesQuery,
  parseQuery,
  stationTerms,
  terms,
  type SearchableStation,
} from './stationSearch';

const stations = (renderedEntries as unknown as (SearchableStation & { transport: string })[])
  .filter((entry) => entry.transport !== 'showcase');
const termsById = new Map(stations.map((vm) => [vm.id, stationTerms(vm)]));

/** Ids matching `query`, in registry order. */
function hits(query: string): string[] {
  const parsed = parseQuery(query);
  return stations.filter((vm) => matchesQuery(termsById.get(vm.id)!, parsed)).map((vm) => vm.id);
}

describe('terms', () => {
  it('splits punctuation AND letter/digit boundaries, which is what makes the shorthands work', () => {
    expect(terms('Windows 3.11')).toEqual(['windows', '3', '11']);
    expect(terms('win3.11')).toEqual(['win', '3', '11']);
    expect(terms('NT4')).toEqual(['nt', '4']);
    expect(terms('x86_64')).toEqual(['x', '86', '64']);
  });

  it('folds case and diacritics so typing plainly still matches', () => {
    expect(terms('Café-OS')).toEqual(['cafe', 'os']);
  });
});

describe('aliasKey', () => {
  it('strips everything that is not alphanumeric, so "3.11" and "311" look up the same', () => {
    expect(aliasKey('3.11')).toBe('311');
    expect(aliasKey('W2K')).toBe('w2k');
  });
});

describe('the query has to survive being typed five different ways', () => {
  it.each(['win2k', 'windows 2000', 'win 2000', 'w2k', '2000'])('%s finds Windows 2000', (query) => {
    expect(hits(query)).toContain('win2000');
  });

  it('win2k reaches the Alpha port too, and stops there', () => {
    // Both machines ARE Windows 2000; nothing else is. Windows XP used to come
    // along because its era is "2000s" — hence dropping `era` from the pools.
    expect(hits('win2k')).toEqual(['win2000', 'w2kalpha']);
  });

  it.each(['win 3', 'win3', 'windows 3', '3.11', 'win31'])('%s finds Windows 3.11', (query) => {
    expect(hits(query)).toContain('win311');
  });

  it('win 3 admits NT 3.51 and nothing else — it is a Windows 3, honestly', () => {
    expect(hits('win 3')).toEqual(['win311', 'nt351']);
  });

  it.each(['irix', 'tru64', 'dos', 'solaris', 'beos', 'xp', 'vms'])('%s finds its own station', (query) => {
    expect(hits(query).length).toBeGreaterThan(0);
  });

  it('irix finds both Indys, tru64 finds exactly one machine', () => {
    expect(hits('irix')).toEqual(['irix', 'indyr4400']);
    expect(hits('tru64')).toEqual(['tru64']);
  });

  it('dos finds the DOS machines, including the one that spells it FreeDOS', () => {
    expect(hits('dos')).toEqual(['freedos', 'win311', 'msdoswin1', 'pcgeos']);
  });
});

describe('unix is a family, not a word', () => {
  const unix = hits('unix');

  it.each(['irix', 'indyr4400', 'tru64', 'solaris', 'sunos414', 'hpuxvue', 'aux', 'nextstep', 'rhapsody', 'newsos', 'pdp11'])(
    'includes %s',
    (id) => { expect(unix).toContain(id); },
  );

  it('nix is the same query', () => {
    expect(hits('nix')).toEqual(unix);
  });

  it('excludes BeOS and Haiku — BeOS is not Unix and neither is its heir', () => {
    expect(unix).not.toContain('beos');
    expect(unix).not.toContain('haiku');
  });

  it('excludes every Windows', () => {
    for (const id of ['win311', 'win95', 'win98se', 'nt351', 'nt4', 'win2000', 'winxp', 'win11', 'w2kalpha']) {
      expect(unix).not.toContain(id);
    }
  });

  it('excludes the 8-bit micros and the Xerox office machines', () => {
    for (const id of ['c64', 'zxspectrum', 'amiga', 'star', 'daybreak', 'alto']) {
      expect(unix).not.toContain(id);
    }
  });
});

describe('a short query must not light up the whole page', () => {
  it('3 finds the machines whose VERSION starts with 3, not everything with a 3 in it', () => {
    const three = hits('3');
    expect(three).toContain('win311');    // Windows 3.11
    expect(three).toContain('nt351');     // NT 3.51
    expect(three).toContain('aux');       // A/UX 3.0.1
    expect(three).toContain('nextstep');  // NeXTSTEP 3.3
    expect(three.length).toBeLessThan(stations.length / 4);
  });

  it('3 does not reach a version 3 buried mid-string, nor a 3 in a clock speed', () => {
    // Substring matching used to hand back Mac OS 7.5.3 for "3"; a 3.5 MHz Z80
    // used to hand back the ZX Spectrum.
    expect(hits('3')).not.toContain('zxspectrum');
    expect(hits('3')).not.toContain('win95');
    expect(hits('3')).not.toContain('winxp');
  });

  it('2000 is a year or a version, not a decade', () => {
    expect(hits('2000')).toEqual(['win2000', 'w2kalpha', 'beos']);
  });

  it('an empty or punctuation-only query matches everything', () => {
    expect(hits('')).toHaveLength(stations.length);
    expect(hits('   ')).toHaveLength(stations.length);
    expect(hits('///')).toHaveLength(stations.length);
  });

  it('a query nothing answers to comes back empty rather than falling back to all', () => {
    expect(hits('zzzznotamachine')).toEqual([]);
  });
});
