// The Nokia 9300 device drawing against agent K1's keymap contract v3
// ($J/K1/keymap-contract.md §3, mirrored in docs/guests/nokia9300.md): every
// drawn key sends its contract keysym, every contract key is drawn, nothing is
// drawn twice, and every legend a visitor can press reaches the station.
import { describe, expect, it } from 'vitest';

import { keysymToScancode } from '../../../three/guestQuirks';
import { charWire } from '../deviceChars';
import { deviceDrawingFor } from '../deviceRegistry';
import { resolvePress } from '../deviceSender';
import { NOKIA9300_DRAWING } from './drawing';
import tableSource from '../../../../../streamhost/stations/nokia9300/x11test.keysyms?raw';

const F = (n: number) => 0xffbe + n - 1;
const code = (c: string) => c.charCodeAt(0);

// Contract v3 §3: key id → the keysym the station injects for it.
const CONTRACT: Record<string, number> = {
  'app.desk': F(5), 'app.tel': F(6), 'app.msg': F(7), 'app.web': F(8),
  'app.contacts': F(9), 'app.docs': F(10), 'app.cal': F(11), 'app.own': F(12),
  cba1: F(1), cba2: F(2), cba3: F(3), cba4: F(4),
  menu: 0xff67, esc: 0xff1b, bksp: 0xff08, tab: 0xff09, enter: 0xff0d, caps: 0xffe5,
  'shift.l': 0xffe1, 'shift.r': 0xffe2, ctrl: 0xffe3, chr: 0xfe03, space: 0x20,
  up: 0xff52, down: 0xff54, left: 0xff51, right: 0xff53,
  'joy.c': F(13), 'joy.u': F(14), 'joy.d': F(15), 'joy.l': F(16), 'joy.r': F(17),
  eq: code('='), hash: code('#'), semi: code(';'), quote: code("'"), slash: code('/'),
  comma: code(','), period: code('.'),
  ...Object.fromEntries('1234567890'.split('').map((d) => [`k${d}`, code(d)])),
  ...Object.fromEntries('abcdefghijklmnopqrstuvwxyz'.split('').map((c) => [c, code(c)])),
};

const keys = NOKIA9300_DRAWING.keys;

// The station's own scancode → keysym table (the daemon's x11test sink).
const stationTable = new Map<number, number>(
  (tableSource as string)
    .split('\n')
    .filter((l: string) => l.trim() && !l.startsWith('#'))
    .map((l: string) => l.split('\t'))
    .map(([sc, plain]: string[]) => [parseInt(sc, 16), parseInt(plain, 16)] as [number, number]),
);
const reachesStation = (keysym: number): boolean => {
  const sc = keysymToScancode(keysym);
  return sc != null && stationTable.has(sc);
};

describe('nokia9300 drawing ↔ keymap contract v3', () => {
  it('draws exactly the contract keys, each once', () => {
    const ids = keys.map((k) => k.id);
    expect(new Set(ids).size, 'a key id is drawn twice').toBe(ids.length);
    expect([...ids].sort()).toEqual(Object.keys(CONTRACT).sort());
  });

  it('every drawn key sends its contract keysym', () => {
    for (const k of keys) expect(k.keysym, k.id).toBe(CONTRACT[k.id]);
  });

  it('no two keys send the same keysym', () => {
    const syms = keys.map((k) => k.keysym);
    expect(new Set(syms).size).toBe(syms.length);
  });

  it('every contract keysym appears on the drawing', () => {
    const drawn = new Set(keys.map((k) => k.keysym));
    for (const [id, ks] of Object.entries(CONTRACT)) expect(drawn.has(ks), id).toBe(true);
  });

  it('every positional press reaches the station table', () => {
    for (const k of keys) {
      for (const ks of resolvePress(k, {})) {
        if (k.kind === 'char') continue; // chars go out as characters (next test)
        expect(reachesStation(ks), `${k.id}: 0x${ks.toString(16)}`).toBe(true);
      }
      const positional = resolvePress({ ...k, kind: 'key' }, {});
      for (const ks of positional) expect(reachesStation(ks), `${k.id} positional 0x${ks.toString(16)}`).toBe(true);
    }
  });

  it('every printed legend character reaches the station', () => {
    for (const k of keys) {
      for (const ch of [k.base, k.shift, k.chr, k.chrShift]) {
        if (!ch) continue;
        const wire = charWire(ch);
        expect(wire, `${k.id}: '${ch}' has no wire`).not.toBeNull();
        expect(reachesStation(wire!.keysym), `${k.id}: '${ch}' is not in the station table`).toBe(true);
      }
    }
  });

  it('the Nordic letters type as their own characters, capitals under Shift', () => {
    const semi = keys.find((k) => k.id === 'semi')!;
    expect(resolvePress(semi, {})).toEqual([0xf6]);
    expect(resolvePress(semi, { shift: 0xffe1 })).toEqual([0xffe1, 0xf6]);
    expect(resolvePress(semi, { chr: 0xfe03 })).toEqual([0xf8]);
    expect(resolvePress(semi, { chr: 0xfe03, shift: 0xffe1 })).toEqual([0xffe1, 0xf8]);
  });
});

describe('nokia9300 drawing geometry', () => {
  it('the drawn display has the stream aspect (1280x400)', () => {
    const s = NOKIA9300_DRAWING.screen;
    expect(s.w / s.h).toBeCloseTo(1280 / 400, 6);
  });

  it('every key lies inside the drawing and outside the display', () => {
    const { w, h } = NOKIA9300_DRAWING.viewBox;
    const s = NOKIA9300_DRAWING.screen;
    for (const k of keys) {
      const b = k.box;
      expect(b.x >= 0 && b.y >= 0 && b.x + b.w <= w && b.y + b.h <= h, k.id).toBe(true);
      const overlapsScreen = b.x < s.x + s.w && b.x + b.w > s.x && b.y < s.y + s.h && b.y + b.h > s.y;
      expect(overlapsScreen, k.id).toBe(false);
    }
  });

  it('no key rectangles overlap, including all five joystick hit zones)', () => {
    const caps = keys;
    for (let i = 0; i < caps.length; i++) {
      for (let j = i + 1; j < caps.length; j++) {
        const a = caps[i].box, b = caps[j].box;
        const hit = a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
        expect(hit, `${caps[i].id} overlaps ${caps[j].id}`).toBe(false);
      }
    }
  });

  it('every modifier role names a drawn mod key', () => {
    for (const id of Object.keys(NOKIA9300_DRAWING.mods)) {
      expect(keys.find((k) => k.id === id)?.kind, id).toBe('mod');
    }
  });
});

describe('deviceRegistry', () => {
  it('presents nokia9300 as the drawing and leaves other stations alone', () => {
    expect(deviceDrawingFor('nokia9300')).toBe(NOKIA9300_DRAWING);
    expect(deviceDrawingFor('win95')).toBeNull();
    expect(deviceDrawingFor('not-a-station')).toBeNull();
  });
});
