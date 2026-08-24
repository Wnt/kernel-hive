// What the scoreboard counts, and what it refuses to count. The interesting
// cases are all subtractive: the numbers are only meaningful if a held Shift, a
// type-in demo and the win9x boot-modal auto-dismiss stay OUT of them.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setDebugTile, clearDebugTile } from './clientDebug';
import {
  __usageReset, __usageTallies, countClick, countKeystroke, flushUsage, withSyntheticInput,
} from './usageStats';

const SHIFT_L = 0x2a;
const ENTER = 0x1c;

function openStation(tile: string) {
  return setDebugTile(tile, { getSnapshot: () => ({}) });
}

describe('usage counters', () => {
  beforeEach(() => {
    __usageReset();
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response('{}', { status: 200 }))));
  });
  afterEach(() => {
    clearDebugTile();
    vi.unstubAllGlobals();
  });

  it('counts presses against the station that is open', () => {
    openStation('win95');
    countClick();
    countKeystroke(ENTER);
    countKeystroke(ENTER);
    expect(__usageTallies()).toEqual({ win95: { clicks: 1, keys: 2 } });
  });

  it('keeps two stations apart', () => {
    const owner = openStation('win95');
    countClick();
    clearDebugTile('win95', owner);
    openStation('beos');
    countKeystroke(ENTER);
    expect(__usageTallies()).toEqual({ win95: { clicks: 1, keys: 0 }, beos: { clicks: 0, keys: 1 } });
  });

  it('drops edges sent while no station is open', () => {
    countClick();
    countKeystroke(ENTER);
    expect(__usageTallies()).toEqual({});
  });

  it('does not count modifiers, so a capital letter is worth one keystroke', () => {
    openStation('win95');
    // Exactly what the char path puts on the wire for "A": a synthetic Shift
    // around the letter (useStreamControl sendCharEvent).
    countKeystroke(SHIFT_L);
    countKeystroke(0x1e); // 'a'
    countKeystroke(SHIFT_L);
    expect(__usageTallies().win95.keys).toBe(1);
  });

  it('does not count software-generated typing', () => {
    openStation('win95');
    withSyntheticInput(() => {
      for (let i = 0; i < 200; i++) countKeystroke(ENTER);
    });
    expect(__usageTallies()).toEqual({});
  });

  it('resumes counting after a synthetic burst, including a nested one', () => {
    openStation('win95');
    withSyntheticInput(() => { withSyntheticInput(() => countKeystroke(ENTER)); countKeystroke(ENTER); });
    countKeystroke(ENTER);
    expect(__usageTallies().win95.keys).toBe(1);
  });

  it('sends what it counted, as one report, and forgets it', async () => {
    openStation('win95');
    countClick();
    countKeystroke(ENTER);
    flushUsage();
    const fetchMock = vi.mocked(globalThis.fetch);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('/usage');
    expect(JSON.parse(String(init?.body))).toEqual({ stations: { win95: { clicks: 1, keys: 1 } } });
    await Promise.resolve();
    expect(__usageTallies()).toEqual({});
  });

  it('sends nothing when there is nothing to say', () => {
    flushUsage();
    expect(vi.mocked(globalThis.fetch)).not.toHaveBeenCalled();
  });

  it('keeps the tally when the box is unreachable', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new Error('offline'))));
    openStation('win95');
    countClick();
    flushUsage();
    await new Promise((r) => setTimeout(r, 0));
    expect(__usageTallies()).toEqual({ win95: { clicks: 1, keys: 0 } });
  });

  it('a tally folded back onto a fresh one adds up', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.reject(new Error('offline'))));
    openStation('win95');
    countClick();
    flushUsage();
    countClick();
    await new Promise((r) => setTimeout(r, 0));
    expect(__usageTallies().win95.clicks).toBe(2);
  });
});
