// Wire-correctness invariants for the per-OS keyboard profiles. These are the
// gate that keeps a silently-dead key (unresolvable scancode, shifted printable
// via sendKey, unbalanced macro, FS-UAE-reserved F11/F12) out of the UI.
import { describe, expect, it } from 'vitest';

import { OS_BINDINGS } from '../../three/archetypeRegistry';
import { asciiToScancode, keysymToScancode } from '../../three/guestQuirks';
import { OS_FAMILY, PROFILES, keyboardProfileFor, type Family } from './keyboardProfiles';
import type { KeyDef, KeyboardProfile } from './keyTypes';

const allProfiles: KeyboardProfile[] = Object.values(PROFILES);
const allDefs = (p: KeyboardProfile): KeyDef[] => [...p.rows, ...(p.moreRows ?? [])].flat();
const sentKeysyms = (d: KeyDef): number[] =>
  d.action === 'macro'
    ? (d.steps ?? []).map((s) => s.keysym)
    : d.action === 'tap' || d.action === 'latch'
      ? [d.keysym ?? -1]
      : [];

describe('OS_FAMILY coverage', () => {
  it('maps every production streamhost tile explicitly', () => {
    const streamhost = Object.values(OS_BINDINGS).filter((b) => b.transport === 'streamhost');
    expect(streamhost.length).toBeGreaterThan(0);
    for (const b of streamhost) {
      expect(OS_FAMILY[b.osId], `OS_FAMILY is missing streamhost tile '${b.osId}'`).toBeDefined();
    }
  });

  it('falls back to generic for unknown osIds', () => {
    expect(keyboardProfileFor('not-a-tile')).toBe(PROFILES.generic);
    expect(keyboardProfileFor('solaris')).toBe(PROFILES.suncde);
  });
});

describe('wire validity', () => {
  it('every tap/latch/macro keysym is client-resolvable to a scancode', () => {
    for (const p of allProfiles) {
      for (const d of allDefs(p)) {
        for (const ks of sentKeysyms(d)) {
          expect(keysymToScancode(ks), `${p.family}/${d.id}: keysym 0x${ks.toString(16)} is unresolvable (silently dead)`).not.toBeNull();
        }
      }
    }
  });

  it('printable-range sendKey keysyms are unshifted (shift flag is discarded)', () => {
    for (const p of allProfiles) {
      for (const d of allDefs(p)) {
        for (const ks of sentKeysyms(d)) {
          if (ks < 0x20 || ks > 0xff) continue;
          const s = asciiToScancode(String.fromCharCode(ks));
          expect(s, `${p.family}/${d.id}: printable 0x${ks.toString(16)} unmapped`).not.toBeNull();
          expect(s!.shift, `${p.family}/${d.id}: shifted printable 0x${ks.toString(16)} would emit the wrong char via sendKey`).toBe(false);
        }
      }
    }
  });

  it('every macro balances its downs/ups and never releases before pressing', () => {
    for (const p of allProfiles) {
      for (const d of allDefs(p)) {
        if (d.action !== 'macro') continue;
        expect(d.steps?.length, `${p.family}/${d.id}: empty macro`).toBeGreaterThan(0);
        const held = new Map<number, number>();
        for (const s of d.steps ?? []) {
          const n = (held.get(s.keysym) ?? 0) + (s.down ? 1 : -1);
          expect(n, `${p.family}/${d.id}: releases 0x${s.keysym.toString(16)} before pressing it`).toBeGreaterThanOrEqual(0);
          held.set(s.keysym, n);
        }
        for (const [ks, n] of held) {
          expect(n, `${p.family}/${d.id}: unbalanced macro for 0x${ks.toString(16)}`).toBe(0);
        }
      }
    }
  });

  it('repeat is only set on tap actions (the never-stick guarantee)', () => {
    for (const p of allProfiles) {
      for (const d of allDefs(p)) {
        if (d.repeat) expect(d.action, `${p.family}/${d.id}: repeat on non-tap`).toBe('tap');
      }
    }
  });

  it('char actions carry exactly one mappable ASCII character', () => {
    for (const p of allProfiles) {
      for (const d of allDefs(p)) {
        if (d.action !== 'char') continue;
        expect(d.char?.length, `${p.family}/${d.id}`).toBe(1);
        expect(asciiToScancode(d.char ?? ''), `${p.family}/${d.id}: char '${d.char}' not typeable`).not.toBeNull();
      }
    }
  });

  it('every key has a non-empty label and a unique id within its profile', () => {
    for (const p of allProfiles) {
      const seen = new Set<string>();
      for (const d of allDefs(p)) {
        expect(d.label.length, `${p.family}/${d.id}: empty label`).toBeGreaterThan(0);
        expect(seen.has(d.id), `${p.family}: duplicate key id '${d.id}'`).toBe(false);
        seen.add(d.id);
      }
    }
  });
});

describe('per-family guardrails', () => {
  it('amiga/aros never emit F11/F12 (FS-UAE reserves them for fullscreen/menu)', () => {
    for (const d of allDefs(PROFILES.amiga)) {
      for (const ks of sentKeysyms(d)) {
        expect(ks === 0xffc8 || ks === 0xffc9, `amiga/${d.id} uses reserved F11/F12`).toBe(false);
      }
    }
    expect(OS_FAMILY.amiga).toBe('amiga');
    expect(OS_FAMILY.aros).toBe('amiga');
  });

  it('base rows stay within the landscape budget (<= 2 rows)', () => {
    for (const p of allProfiles) {
      expect(p.rows.length, `${p.family}: too many always-visible rows`).toBeLessThanOrEqual(2);
    }
  });

  // The stream toolbar's Ctrl+Alt+Del button is gone: this key IS the function
  // now, so a profile that has it must show it without a detour. moreRows is a
  // detour — landscape hides those rows outright.
  it('every PC-style profile carries C-A-D in an always-visible base row', () => {
    const PC: Family[] = ['generic', 'linux-tty', 'windows', 'win3x', 'dos', 'os2', 'suncde'];
    for (const family of PC) {
      const p = PROFILES[family];
      expect(p.rows.flat().some((d) => d.id === 'cad'), `${family}: C-A-D missing from the base rows`).toBe(true);
      expect(
        (p.moreRows ?? []).flat().some((d) => d.id === 'cad'),
        `${family}: C-A-D hidden in moreRows, which landscape does not render`,
      ).toBe(false);
    }
  });

  it('keeps C-A-D a single-tap key wherever it appears', () => {
    for (const p of allProfiles) {
      for (const d of [...p.rows, ...(p.moreRows ?? [])].flat()) {
        if (d.id === 'cad') expect(d.danger, `${p.family}: C-A-D requires a confirm tap`).not.toBe(true);
      }
    }
  });
});
