// The header's chord chip must never name a key the device does not have.
import { describe, expect, it } from 'vitest';
import { jumpChord } from './jumpChord';

describe('jumpChord', () => {
  it('offers no chord at all to a finger', () => {
    // The Android phone the ⌘K chip was found on: a real keyboard may well be
    // paired, but the primary pointer is a finger and the affordance is a tap.
    expect(jumpChord({ platform: 'Android', coarsePrimary: true })).toBeNull();
    expect(jumpChord({ platform: 'MacIntel', coarsePrimary: true })).toBeNull();
  });

  it('names Command only on Apple platforms', () => {
    expect(jumpChord({ platform: 'macOS', coarsePrimary: false })).toBe('⌘K');
    expect(jumpChord({ platform: 'MacIntel', coarsePrimary: false })).toBe('⌘K');
    expect(jumpChord({ platform: 'iPad', coarsePrimary: false })).toBe('⌘K');
  });

  it('names Ctrl everywhere else, where the shortcut really is Ctrl', () => {
    expect(jumpChord({ platform: 'Linux x86_64', coarsePrimary: false })).toBe('Ctrl K');
    expect(jumpChord({ platform: 'Windows', coarsePrimary: false })).toBe('Ctrl K');
    // No hint at all is still a desktop with a keyboard: Ctrl is the safe read.
    expect(jumpChord({ platform: '', coarsePrimary: false })).toBe('Ctrl K');
  });
});
