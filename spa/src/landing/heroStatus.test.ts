import { describe, expect, it } from 'vitest';
import { POSTER_FALLBACK_CAPTION, heroCaption, pickMediaSize, runStateLabel, statusCells } from './heroStatus';

describe('pickMediaSize', () => {
  it('takes the first element that has actually decoded something', () => {
    // A <video> reports 0x0 until the first frame; a hidden paint canvas can
    // report 0 forever. Neither is a small picture.
    expect(pickMediaSize([{ width: 0, height: 0 }, { width: 1024, height: 768 }]))
      .toEqual({ width: 1024, height: 768 });
  });

  it('is null while nothing has decoded — never 0x0 on the strip', () => {
    expect(pickMediaSize([{ width: 0, height: 0 }, {}])).toBeNull();
    expect(pickMediaSize([])).toBeNull();
  });

  it('rejects a half-measured element rather than reporting one axis', () => {
    expect(pickMediaSize([{ width: 640, height: 0 }])).toBeNull();
  });
});

describe('statusCells', () => {
  it('reads like the strip on a running machine', () => {
    expect(statusCells({
      state: 'running',
      size: { width: 1024, height: 768 },
      lineage: 'MS-DOS + Windows 3.x',
      station: 'win311',
    })).toEqual(['RUNNING', '1024×768', 'MS-DOS + Windows 3.x', 'win311']);
  });

  it('DROPS the resolution until a frame has arrived, rather than faking one', () => {
    expect(statusCells({ state: 'connecting', size: null, station: 'win311' }))
      .toEqual(['CONNECTING', 'win311']);
  });

  it('never claims RUNNING for a state that is not running', () => {
    for (const state of ['poster', 'connecting', 'queued', 'stopped'] as const) {
      expect(runStateLabel(state)).not.toBe('RUNNING');
    }
    expect(runStateLabel('running')).toBe('RUNNING');
  });
});

describe('POSTER_FALLBACK_CAPTION', () => {
  it('does not repeat the capability sentence printed across the poster', () => {
    expect(POSTER_FALLBACK_CAPTION).not.toMatch(/WebRTC|WebTransport|browser/i);
  });

  it('says what this visitor can still do instead', () => {
    expect(POSTER_FALLBACK_CAPTION).toMatch(/collection|placard/i);
  });
});

describe('heroCaption', () => {
  it('names the machine the visitor is actually driving', () => {
    expect(heroCaption('running', 'os2warp')).toContain('os2warp');
  });

  it('promises nothing it cannot keep before the first frame', () => {
    expect(heroCaption('connecting', 'win311')).not.toMatch(/going straight into/);
  });

  it('is honest on the poster fallback', () => {
    expect(heroCaption('poster', null)).toMatch(/still/i);
  });

  it('says WHY the machine went away, per reason', () => {
    // A visitor who is not told the page took the machine back assumes it
    // broke, and reloads — the one reaction that makes the pool worse.
    expect(heroCaption('stopped', 'win311', 'never-driven')).toMatch(/still there\?/i);
    expect(heroCaption('stopped', 'win311', 'hidden')).toMatch(/background/i);
    expect(heroCaption('stopped', 'win311', 'left')).toMatch(/gone back to the pool/i);
    expect(heroCaption('stopped', 'win311')).toMatch(/gone back to the pool/i);
  });

  it('names the machine it is offering back, not "another one"', () => {
    // The second half of the operator's bug: the page used to say "take
    // another" and then hand the visitor a different OS. It now offers back
    // the machine they were on, so the sentence has to name it.
    for (const stop of ['never-driven', 'hidden', 'left'] as const) {
      expect(heroCaption('stopped', 'win311', stop)).toContain('win311');
    }
  });

  it('never promises the visitor their work survived', () => {
    // The pool never recycles a used clone, so a machine that comes back is a
    // FRESH copy. Saying "the same machine" and handing over a clean desktop
    // is the one lie on this page a visitor would actually notice.
    for (const stop of ['never-driven', 'hidden', 'left'] as const) {
      expect(heroCaption('stopped', 'win311', stop)).toMatch(/clean copy/i);
    }
  });

  it('never says "disconnected" or leaves a stopped stage wordless', () => {
    for (const stop of ['never-driven', 'hidden', 'left'] as const) {
      const line = heroCaption('stopped', 'win311', stop);
      expect(line).not.toMatch(/disconnect/i);
      expect(line).toMatch(/bring it back/i);
    }
  });

  it('does not start counting a minute the visitor has not started', () => {
    const waiting = heroCaption('running', 'win311', undefined, false);
    expect(waiting).toMatch(/intro time does not start until you click or type/i);
    expect(heroCaption('running', 'win311', undefined, true))
      .not.toMatch(/intro time does not start until you click or type/i);
  });

  it('always has words, for every state', () => {
    for (const state of ['poster', 'connecting', 'running', 'queued', 'stopped'] as const) {
      expect(heroCaption(state, null).length).toBeGreaterThan(20);
    }
  });
});
