import { describe, expect, it, vi } from 'vitest';

import { collect, encodeLines, installCoverageReporter } from './coverage';

type Cov = Record<string, { statementMap: Record<string, { start: { line: number } }>; s: Record<string, number> }>;

function withCoverage<T>(cov: Cov | undefined, fn: () => T): T {
  const holder = globalThis as { __coverage__?: Cov };
  const before = holder.__coverage__;
  if (cov) holder.__coverage__ = cov; else delete holder.__coverage__;
  try {
    return fn();
  } finally {
    if (before) holder.__coverage__ = before; else delete holder.__coverage__;
  }
}

/** The encoding the server re-reads (scripts/serve/linecov.py decode_lines). */
function decode(rle: string): number[] {
  if (!rle) return [];
  const parts = rle.split('.');
  const out: number[] = [];
  let prev = 0;
  for (let i = 0; i < parts.length; i += 2) {
    const start = prev + parseInt(parts[i], 36);
    const run = parseInt(parts[i + 1], 36);
    for (let k = 0; k < run; k += 1) out.push(start + k);
    prev = start + run - 1;
  }
  return out;
}

describe('encodeLines', () => {
  it('round-trips through the decoder the server uses', () => {
    for (const lines of [[1], [1, 2, 3], [5, 6, 9, 40, 41, 42], [7, 900, 901]]) {
      expect(decode(encodeLines(new Set(lines)))).toEqual(lines);
    }
  });

  it('encodes the empty set as the empty string', () => {
    // Not a cosmetic choice: a file with no executed lines is the finding this
    // plane exists for, so it must survive the wire rather than look malformed.
    expect(encodeLines(new Set())).toBe('');
  });

  it('collapses a run into two tokens however long it is', () => {
    const long = new Set(Array.from({ length: 400 }, (_, i) => i + 1));
    expect(encodeLines(long).split('.')).toHaveLength(2);
  });
});

describe('collect', () => {
  it('is empty, not thrown, when the bundle is not instrumented', () => {
    expect(withCoverage(undefined, collect)).toEqual([]);
  });

  it('reduces hit COUNTS to a hit SET and drops the counts', () => {
    const rows = withCoverage(
      {
        '/build/spa/src/a.ts': {
          statementMap: { 0: { start: { line: 3 } }, 1: { start: { line: 4 } }, 2: { start: { line: 9 } } },
          s: { 0: 412, 1: 0, 2: 1 },
        },
      },
      collect,
    );
    expect(rows).toHaveLength(1);
    expect(rows[0].f).toBe('src/a.ts');
    expect(decode(rows[0].a)).toEqual([3, 4, 9]);
    expect(decode(rows[0].h)).toEqual([3, 9]);
    // 412 is how many times a line ran, which is a behavioural trace and is
    // never sent; the question is only whether it ran at all.
    expect(JSON.stringify(rows)).not.toContain('412');
  });

  it('reports a file that never ran, rather than omitting it', () => {
    const rows = withCoverage(
      { '/build/spa/src/dead.ts': { statementMap: { 0: { start: { line: 1 } } }, s: { 0: 0 } } },
      collect,
    );
    expect(rows[0].h).toBe('');
    expect(rows[0].a).not.toBe('');
  });

  it('sends the spa-relative path, never the build machine s absolute one', () => {
    const rows = withCoverage(
      {
        '/data/vms/sandbox/somebody/repo/spa/src/ui/x.tsx': {
          statementMap: { 0: { start: { line: 1 } } },
          s: { 0: 1 },
        },
      },
      collect,
    );
    expect(rows[0].f).toBe('src/ui/x.tsx');
  });
});

describe('installCoverageReporter', () => {
  it('never throws when there is no window to hook', () => {
    expect(() => installCoverageReporter('abc123')).not.toThrow();
  });

  it('sends nothing at all when the bundle carries no coverage', () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    withCoverage(undefined, () => installCoverageReporter('abc123'));
    expect(fetchSpy).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });
});
