import { describe, expect, it } from 'vitest';
import { heroCaption, pickMediaSize, runStateLabel, statusCells } from './heroStatus';

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
    expect(heroCaption('stopped', 'win311', 'never-driven')).toMatch(/nothing was clicked/i);
    expect(heroCaption('stopped', 'win311', 'hidden')).toMatch(/background/i);
    expect(heroCaption('stopped', 'win311', 'left')).toMatch(/handed back/i);
    expect(heroCaption('stopped', 'win311')).toMatch(/handed back/i);
  });

  it('never says "disconnected" or leaves a stopped stage wordless', () => {
    for (const stop of ['never-driven', 'hidden', 'left'] as const) {
      const line = heroCaption('stopped', 'win311', stop);
      expect(line).not.toMatch(/disconnect/i);
      expect(line).toMatch(/take another/i);
    }
  });

  it('always has words, for every state', () => {
    for (const state of ['poster', 'connecting', 'running', 'queued', 'stopped'] as const) {
      expect(heroCaption(state, null).length).toBeGreaterThan(20);
    }
  });
});
