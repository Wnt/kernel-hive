// Tests for the compose lane. Each one guards a way these three numbers could
// state something confident and untrue about a hand-maintained keyboard layout:
// a correction rate computed from a denominator that was not there, a held key
// counted as a hundred, an episode's effort reported as a distribution of ones.

import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { composeTelemetry, correctionRatePct, effectOf } from './composeTelemetry';
import { XK } from '../../three/useStreamControl';
import { __resetMetrics } from '../../analytics/metrics';
import { __resetFlows } from '../../analytics/flows';
import { configureSink, __pendingBatch, __resetSink } from '../../analytics/sink';

beforeEach(() => {
  __resetMetrics();
  __resetFlows();
  __resetSink();
  configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
  (globalThis as { document?: unknown }).document = {
    visibilityState: 'visible',
    addEventListener: () => {},
  };
});

afterEach(() => { delete (globalThis as { document?: unknown }).document; });

const metric = (id: string) => __pendingBatch().metrics.filter((m) => m.id === id);
const flow = () => __pendingBatch().flows.filter((f) => f.flow === 'keyboard.compose');

describe('what one key press did', () => {
  it('counts a glyph as a committed character', () => {
    expect(effectOf({ action: 'char' })).toBe('commit');
  });

  it('counts the SPACE BAR as a character even though it is a tap', () => {
    // Space is a `tap` on keysym 0x20, not a `char` (qwertyLayout QFUNC), so
    // without naming it here every space typed would go missing from the
    // denominator and every correction rate would read high.
    expect(effectOf({ action: 'tap', keysym: 0x20 })).toBe('commit');
  });

  it('counts Backspace as a correction', () => {
    expect(effectOf({ action: 'tap', keysym: XK.BackSpace })).toBe('correct');
  });

  it('counts a modifier, an arrow and a macro as NEITHER half of the rate', () => {
    // Real keyboard work, but neither a character nor a taking-back of one;
    // putting them in either half would make the rate a function of how many
    // arrow keys the layout happens to show.
    expect(effectOf({ action: 'latch', keysym: XK.BackSpace + 1 })).toBe('other');
    expect(effectOf({ action: 'tap', keysym: XK.Return })).toBe('other');
    expect(effectOf({ action: 'macro' })).toBe('other');
  });
});

describe('the correction rate definition', () => {
  it('is backspaces over characters committed, as a percentage', () => {
    expect(correctionRatePct(1, 4)).toBe(25);
    expect(correctionRatePct(3, 10)).toBeCloseTo(30);
  });

  it('reports ZERO for a clean episode — the layout working is a sample', () => {
    expect(correctionRatePct(0, 12)).toBe(0);
  });

  it('reports NOTHING when no character was committed', () => {
    // Corrections over an empty denominator is not a small percentage, it is
    // not a percentage. The episode is still visible as one that never reached
    // `text` in the funnel.
    expect(correctionRatePct(3, 0)).toBeNull();
    expect(correctionRatePct(0, 0)).toBeNull();
  });

  it('lets a rate over 100 through rather than clamping it', () => {
    // More deletions than characters typed is real — clearing a field the guest
    // already had text in — and it must land in `inf` rather than being merged
    // with the merely-terrible episodes at 100.
    expect(correctionRatePct(9, 3)).toBe(300);
  });

  it('refuses nonsense instead of producing a number from it', () => {
    expect(correctionRatePct(Number.NaN, 4)).toBeNull();
    expect(correctionRatePct(1, Number.POSITIVE_INFINITY)).toBeNull();
  });
});

describe('one episode is one sample', () => {
  it('reports a single bucketed rate for the whole episode', () => {
    const t = composeTelemetry();
    t.key({ action: 'char' });
    t.key({ action: 'char' });
    t.key({ action: 'char' });
    t.key({ action: 'char' });
    t.key({ action: 'tap', keysym: XK.BackSpace });
    t.ended();
    // 1 of 4 = 25% → the 30 decile, once, not five samples of one.
    expect(metric('keyboard.compose.correctionsPct')).toEqual([
      { id: 'keyboard.compose.correctionsPct', bucket: '30', n: 1 },
    ]);
  });

  it('reports layer switches as one per-episode total, including a zero', () => {
    const clean = composeTelemetry();
    clean.key({ action: 'char' });
    clean.ended();
    expect(metric('keyboard.compose.layerSwitches')).toEqual([
      { id: 'keyboard.compose.layerSwitches', bucket: '1', n: 1 },
    ]);
  });

  it('adds free-text commits into the same two halves as the grid keys', () => {
    // The device IME proxy and the key grid are one episode of typing, and
    // splitting them would report a visitor who used both as two half-episodes.
    const t = composeTelemetry();
    t.freeText(0, 8);
    t.key({ action: 'tap', keysym: XK.BackSpace });
    t.key({ action: 'tap', keysym: XK.BackSpace });
    t.ended();
    expect(metric('keyboard.compose.correctionsPct')).toEqual([
      { id: 'keyboard.compose.correctionsPct', bucket: '30', n: 1 },
    ]);
  });

  it('commits once — a second end is ignored', () => {
    const t = composeTelemetry();
    t.key({ action: 'char' });
    t.ended();
    t.ended();
    expect(metric('keyboard.compose.correctionsPct')).toHaveLength(1);
    expect(metric('keyboard.compose.layerSwitches')).toHaveLength(1);
  });
});

describe('the compose funnel', () => {
  it('does not record a first-key time for a keyboard nobody typed on', () => {
    // An abandoned timing is not a zero: a sheet opened and closed has no first
    // key at all, and a zero would be the fastest sample in the distribution.
    const t = composeTelemetry();
    t.ended();
    expect(metric('keyboard.compose.toFirstKeyMs')).toEqual([]);
  });

  it('completes only when a character actually reached the guest', () => {
    const typed = composeTelemetry();
    typed.key({ action: 'char' });
    typed.ended();
    expect(flow().some((f) => f.outcome === 'ok')).toBe(true);
  });

  it('leaves a keyboard opened and dismissed to the funnel, not to `fail`', () => {
    // Abandonment is already the drop-off; reporting it as a fault would
    // double-count every dismissal as a defect.
    __resetSink();
    configureSink({ sessionId: 'test', allowed: true, clientClass: () => 'human' });
    const t = composeTelemetry();
    t.key({ action: 'latch' });
    t.ended();
    expect(flow().some((f) => f.outcome === 'fail')).toBe(false);
    expect(flow().some((f) => f.outcome === 'ok')).toBe(false);
    // …but it did reach `firstKey`, which is what tells a dismissed keyboard
    // apart from one where no key was ever found.
    expect(flow().some((f) => f.step === 'firstKey')).toBe(true);
  });
});
