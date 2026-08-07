// Truth table for the mobile-layout predicate: the layout restructure keys on
// TouchEvent presence AND a coarse PRIMARY pointer (touch-laptops stay desktop).
import { describe, expect, it } from 'vitest';
import { isMobileLayout } from './useMobileLayout';

describe('isMobileLayout', () => {
  it('is true only for touch + coarse-primary devices', () => {
    expect(isMobileLayout({ touch: true, coarsePrimary: true })).toBe(true);
  });

  it('keeps touchscreen laptops (fine primary pointer) on the desktop layout', () => {
    expect(isMobileLayout({ touch: true, coarsePrimary: false })).toBe(false);
  });

  it('is false without touch events, regardless of pointer coarseness', () => {
    expect(isMobileLayout({ touch: false, coarsePrimary: true })).toBe(false);
    expect(isMobileLayout({ touch: false, coarsePrimary: false })).toBe(false);
  });
});
