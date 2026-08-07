// Unit coverage for the device-follows-model rule (input/pointerModeAuto): an
// S-Pen in hover range takes direct pointing, a finger hands the surface back to
// the trackpad, and a hand resting on the glass mid-stylus-stroke does not.
import { describe, expect, it } from 'vitest';
import { autoModel, isPrecisePointer, PRECISE_GRACE_MS, type TouchModel } from './pointerModeAuto';

const base = { isDown: false, nowMs: 10_000, preciseAtMs: -Infinity, model: 'trackpad' as TouchModel };

describe('pointerModeAuto — which model the surface should be in', () => {
  it('a HOVERING stylus switches to direct before its tip ever lands', () => {
    // buttons===0, no contact: this is the whole point of watching hover.
    expect(autoModel({ ...base, pointerType: 'pen' })).toBe('direct');
  });

  it('a mouse also wants direct pointing (a hybrid laptop, a desktop touchscreen)', () => {
    expect(autoModel({ ...base, pointerType: 'mouse' })).toBe('direct');
    expect(isPrecisePointer('mouse')).toBe(true);
    expect(isPrecisePointer('touch')).toBe(false);
  });

  it('a finger CONTACT hands the surface back once the stylus has been away', () => {
    const away = { ...base, model: 'direct' as TouchModel, preciseAtMs: 10_000 - PRECISE_GRACE_MS };
    expect(autoModel({ ...away, pointerType: 'touch', isDown: true })).toBe('trackpad');
  });

  it('a hand resting on the glass mid-stroke does NOT steal the stylus its model', () => {
    // The pen was seen 200 ms ago — it is in the visitor's hand, not put down.
    const near = { ...base, model: 'direct' as TouchModel, preciseAtMs: 9_800 };
    expect(autoModel({ ...near, pointerType: 'touch', isDown: true })).toBe('direct');
  });

  it('a finger MOVE never flips the model on its own — only a contact does', () => {
    const away = { ...base, model: 'direct' as TouchModel, preciseAtMs: 0 };
    expect(autoModel({ ...away, pointerType: 'touch', isDown: false })).toBe('direct');
  });

  it('holds the current model for anything it has no opinion about', () => {
    expect(autoModel({ ...base, pointerType: '' })).toBe('trackpad');
    expect(autoModel({ ...base, model: 'direct', pointerType: '' })).toBe('direct');
  });
});
