// deviceSender: hold = hold, the Shift/Ctrl/Chr latches, Chr held alone, the
// 150 ms pacing, and that nothing is left down. Driven on the nokia9300 drawing
// with a fake clock.
import { describe, expect, it } from 'vitest';

import { charWire } from './deviceChars';
import { createDeviceSender, DEVICE_KEY_GAP_MS } from './deviceSender';
import { NOKIA9300_DRAWING } from './nokia9300/drawing';

const SHIFT_L = 0xffe1, CTRL_L = 0xffe3, CHR = 0xfe03, UP = 0xff52;

function rig() {
  let t = 0;
  let timers: { at: number; fn: () => void; live: boolean }[] = [];
  const wire: { ks: number; down: boolean; at: number }[] = [];
  const sender = createDeviceSender(
    NOKIA9300_DRAWING,
    () => ({ sendKey: (ks, down) => wire.push({ ks, down, at: t }) }),
    {
      now: () => t,
      timer: (fn, ms) => {
        const e = { at: t + ms, fn, live: true };
        timers.push(e);
        return () => { e.live = false; };
      },
    },
  );
  const advance = (ms: number) => {
    const end = t + ms;
    for (;;) {
      const due = timers.filter((e) => e.live && e.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      due.live = false;
      t = due.at;
      due.fn();
    }
    timers = timers.filter((e) => e.live);
    t = end;
  };
  const edges = () => wire.map((e) => `${e.down ? '+' : '-'}${e.ks.toString(16)}`);
  const tap = (id: string, holdMs = 50) => { sender.press(id); advance(holdMs); sender.release(id); advance(1000); };
  return { sender, advance, wire, edges, tap };
}

describe('deviceSender', () => {
  it('press is key-down and release is key-up, however long the hold', () => {
    const r = rig();
    r.sender.press('app.desk');
    r.advance(3000);
    expect(r.edges()).toEqual(['+ffc2']);
    r.sender.release('app.desk');
    r.advance(1000);
    expect(r.edges()).toEqual(['+ffc2', '-ffc2']);
  });

  it(`paces every edge at least ${DEVICE_KEY_GAP_MS} ms apart`, () => {
    const r = rig();
    for (const id of ['q', 'w', 'e']) { r.sender.press(id); r.sender.release(id); }
    r.advance(5000);
    expect(r.edges()).toEqual(['+71', '-71', '+77', '-77', '+65', '-65']);
    for (let i = 1; i < r.wire.length; i++) {
      expect(r.wire[i].at - r.wire[i - 1].at).toBeGreaterThanOrEqual(DEVICE_KEY_GAP_MS);
    }
  });

  it('a tapped Shift latches for one key and types that key\'s Shift legend', () => {
    const r = rig();
    r.tap('shift.l');
    expect(r.sender.snapshot().latched.has('shift')).toBe(true);
    expect(r.edges()).toEqual([]); // Shift is not held on the wire for printables
    r.tap('k1'); // Nordic Shift+1 = '!'
    expect(r.edges()).toEqual([`+${SHIFT_L.toString(16)}`, '+31', '-31', `-${SHIFT_L.toString(16)}`]);
    expect(r.sender.snapshot().latched.size).toBe(0);
    r.tap('k1');
    expect(r.edges().slice(4)).toEqual(['+31', '-31']);
  });

  it('tapping a latched Shift again unlatches it', () => {
    const r = rig();
    r.tap('shift.l');
    r.tap('shift.r');
    expect(r.sender.snapshot().latched.size).toBe(0);
  });

  it('Chr types a Chr character as that character, and a Chr function with Chr held', () => {
    const r = rig();
    r.tap('chr');
    r.tap('k4'); // Nordic Chr+4 = '$' = US Shift+4
    expect(r.edges()).toEqual(['+ffe1', '+34', '-34', '-ffe1']);
    r.tap('chr');
    r.tap('up'); // Chr+Up = zoom in: positional, Chr really held
    expect(r.edges().slice(4)).toEqual([`+${CHR.toString(16)}`, `+${UP.toString(16)}`, `-${UP.toString(16)}`, `-${CHR.toString(16)}`]);
  });

  it('Ctrl held (multi-touch) wraps the key\'s own keysym and stays for the next key', () => {
    const r = rig();
    r.sender.press('ctrl');
    r.tap('a');
    r.tap('c');
    r.sender.release('ctrl');
    r.advance(1000);
    expect(r.edges()).toEqual(['+ffe3', '+61', '-61', '-ffe3', '+ffe3', '+63', '-63', '-ffe3']);
    // Held and used: releasing it does not latch it.
    expect(r.sender.snapshot().latched.size).toBe(0);
    expect(CTRL_L).toBe(0xffe3);
  });

  it('Chr held alone goes down for real (the character map), and up on release', () => {
    const r = rig();
    r.sender.press('chr');
    r.advance(200);
    expect(r.edges()).toEqual([]);
    r.advance(600);
    expect(r.edges()).toEqual(['+fe03']);
    r.sender.release('chr');
    r.advance(1000);
    expect(r.edges()).toEqual(['+fe03', '-fe03']);
    expect(r.sender.snapshot().latched.size).toBe(0);
  });

  it('a modifier two held keys share goes up with the last of them', () => {
    const r = rig();
    r.sender.press('shift.l');
    r.sender.press('left');
    r.sender.press('up');
    r.advance(1000);
    r.sender.release('left');
    r.advance(1000);
    expect(r.edges()).toEqual(['+ffe1', '+ff51', '+ff52', '-ff51']);
    r.sender.release('up');
    r.sender.release('shift.l');
    r.advance(1000);
    expect(r.edges().slice(4)).toEqual(['-ff52', '-ffe1']);
  });

  it('releaseAll drops queued edges and lifts what is down, at once', () => {
    const r = rig();
    r.sender.press('shift.l');
    r.sender.press('right');
    r.sender.press('q');
    r.advance(10); // Shift_L went out; Right and q are still queued
    r.sender.releaseAll();
    expect(r.edges()).toEqual(['+ffe1', '-ffe1']);
    expect(r.sender.snapshot().pressed.size).toBe(0);
  });

  it('shows pressed keys and latched modifiers', () => {
    const r = rig();
    let calls = 0;
    const off = r.sender.subscribe(() => { calls++; });
    r.sender.press('menu');
    expect(r.sender.snapshot().pressed.has('menu')).toBe(true);
    r.sender.release('menu');
    expect(r.sender.snapshot().pressed.has('menu')).toBe(false);
    off();
    expect(calls).toBe(2);
  });

  it('ignores unknown ids and a second press of a held key', () => {
    const r = rig();
    r.sender.press('nope');
    r.sender.release('nope');
    r.sender.press('z');
    r.sender.press('z');
    r.sender.release('z');
    r.advance(1000);
    expect(r.edges()).toEqual(['+7a', '-7a']);
  });
});

describe('charWire', () => {
  it('maps US-shifted symbols to their key with Shift', () => {
    expect(charWire('?')).toEqual({ keysym: 0x2f, shift: true });
    expect(charWire('Q')).toEqual({ keysym: 0x71, shift: true });
    expect(charWire('-')).toEqual({ keysym: 0x2d, shift: false });
  });

  it('maps the Nordic and currency characters to their own keysyms', () => {
    expect(charWire('ä')).toEqual({ keysym: 0xe4, shift: false });
    expect(charWire('Å')).toEqual({ keysym: 0xe5, shift: true });
    expect(charWire('€')).toEqual({ keysym: 0x20ac, shift: false });
    expect(charWire('£')).toEqual({ keysym: 0xa3, shift: false });
  });

  it('refuses what the wire cannot carry', () => {
    expect(charWire('ß')).toBeNull();
    expect(charWire('')).toBeNull();
  });
});
