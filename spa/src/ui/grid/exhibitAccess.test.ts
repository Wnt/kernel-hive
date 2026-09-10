import { describe, expect, it } from 'vitest';
import { exhibitViewFor } from './exhibitAccess';

// The regression this file guards: opening an exhibit nobody (or not THIS
// role) can drive landed on StreamView's live-stub note, or — for a walk-in
// — a redirect that silently dropped the /os/:osId URL. Both should be the
// exhibit's own notes instead, with the stub kept only for the one case
// notes cannot cover: no poster document at all.

describe('exhibitViewFor', () => {
  describe('showcase transport — nobody can drive it, for any role', () => {
    for (const role of ['admin', 'viewer', 'walkin', 'anon'] as const) {
      it(`shows notes to ${role} when a poster exists`, () => {
        expect(exhibitViewFor(role, 'showcase', true)).toBe('notes');
      });

      it(`falls back to the stub for ${role} when no poster exists`, () => {
        expect(exhibitViewFor(role, 'showcase', false)).toBe('stub');
      });
    }
  });

  describe('streamhost transport — an invited session is unaffected', () => {
    for (const role of ['admin', 'viewer'] as const) {
      it(`streams for ${role} regardless of poster coverage`, () => {
        expect(exhibitViewFor(role, 'streamhost', true)).toBe('stream');
        expect(exhibitViewFor(role, 'streamhost', false)).toBe('stream');
      });
    }
  });

  describe('streamhost transport — a walk-in or anonymous stranger cannot drive the shared tile', () => {
    for (const role of ['walkin', 'anon'] as const) {
      it(`shows notes to ${role} when a poster exists`, () => {
        expect(exhibitViewFor(role, 'streamhost', true)).toBe('notes');
      });

      it(`falls back to the stub for ${role} when no poster exists`, () => {
        expect(exhibitViewFor(role, 'streamhost', false)).toBe('stub');
      });
    }
  });
});
