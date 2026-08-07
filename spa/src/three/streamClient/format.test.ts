import { describe, expect, it } from 'vitest';
import { codecStringFor, profileName, levelName, presetName, clampU16, clampI16, clamp0100 } from './format';

describe('codecStringFor', () => {
  it('constrained-baseline uses constraint flags 0xe0', () => {
    expect(codecStringFor(66, 0x1e)).toBe('avc1.42e01e'); // Baseline L3.0
    expect(codecStringFor(66, 0x28)).toBe('avc1.42e028'); // Baseline L4.0
  });
  it('main/high use constraint flags 0x00', () => {
    expect(codecStringFor(77, 0x1f)).toBe('avc1.4d001f'); // Main L3.1
    expect(codecStringFor(100, 0x28)).toBe('avc1.640028'); // High L4.0
  });
});

describe('profileName / levelName / presetName', () => {
  it('maps the known profile_idc values', () => {
    expect(profileName(66)).toBe('Baseline');
    expect(profileName(77)).toBe('Main');
    expect(profileName(100)).toBe('High');
    expect(profileName(244)).toBe('P244');
  });
  it('level_idc is level×10', () => {
    expect(levelName(0x28)).toBe('4.0'); // 40 → 4.0
    expect(levelName(31)).toBe('3.1');
    expect(levelName(0x33)).toBe('5.1'); // 51 → 5.1
  });
  it('preset_enum indexes the libx264 preset ladder', () => {
    expect(presetName(0)).toBe('ultrafast');
    expect(presetName(5)).toBe('medium');
    expect(presetName(8)).toBe('veryslow');
    expect(presetName(9)).toBe('p9'); // out of range → pN
  });
});

describe('clamps (wire encoders)', () => {
  it('clampU16 rounds and saturates to 0..65535', () => {
    expect(clampU16(-1)).toBe(0);
    expect(clampU16(70000)).toBe(65535);
    expect(clampU16(3.6)).toBe(4);
  });
  it('clampI16 rounds and saturates to -32768..32767', () => {
    expect(clampI16(-40000)).toBe(-32768);
    expect(clampI16(40000)).toBe(32767);
    expect(clampI16(-3.4)).toBe(-3);
  });
  it('clamp0100 saturates to 0..100 without rounding', () => {
    expect(clamp0100(-5)).toBe(0);
    expect(clamp0100(150)).toBe(100);
    expect(clamp0100(42.5)).toBe(42.5);
  });
});
