// Truth table for the right-click-arm / keyboard-opener mount gate. See
// touchChromeGate.ts's header for why `docked` alone is not enough.
import { describe, expect, it } from 'vitest';
import { showsTouchChrome } from './touchChromeGate';

describe('showsTouchChrome', () => {
  it('hides the badges on a desktop mini display (docked, no coarse pointer)', () => {
    expect(showsTouchChrome({ mobile: false, docked: true, touchCapable: false })).toBe(false);
  });

  it('shows the badges on a touch mini display (docked + touch-capable)', () => {
    expect(showsTouchChrome({ mobile: false, docked: true, touchCapable: true })).toBe(true);
  });

  it('shows the badges on the full station view for a touch exhibit, docked or not', () => {
    expect(showsTouchChrome({ mobile: true, docked: false, touchCapable: true })).toBe(true);
    expect(showsTouchChrome({ mobile: true, docked: true, touchCapable: true })).toBe(true);
  });

  it('hides the badges on the full desktop station view (never docked, no coarse pointer)', () => {
    expect(showsTouchChrome({ mobile: false, docked: false, touchCapable: false })).toBe(false);
  });

  it('keeps the arm for an S-Pen tablet (fine primary pointer, coarse touch surface) when docked', () => {
    // mobile=false because useMobileLayout keys on the PRIMARY pointer only;
    // touchCapable=true because env.isTouchDevice() checks any-pointer:coarse.
    expect(showsTouchChrome({ mobile: false, docked: true, touchCapable: true })).toBe(true);
  });
});
