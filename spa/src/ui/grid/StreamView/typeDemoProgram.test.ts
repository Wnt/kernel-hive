import { describe, expect, it } from 'vitest';
import type { DemoProgram } from '../../../types';
import {
  DEMO_ENTER_DELAY_MS, DEMO_LINE_DELAY_MS, DEMO_PER_CHAR_MS, applyKeyboard, typeDemoProgram,
} from './typeDemoProgram';
import { demoProgramFor } from '../../../data/demoPrograms';
import { keyboardFor } from '../../../data/keyboards';

const PROGRAM: DemoProgram = {
  label: 'Type in a demo program',
  lines: ['10 MODE 1', '20 PRINT "HI"'],
  runCommand: 'RUN',
};

function recorder() {
  const typed: string[] = [];
  const waits: number[] = [];
  return {
    typed,
    waits,
    handle: { typeText: (t: string) => typed.push(t) },
    sleep: async (ms: number) => { waits.push(ms); },
  };
}

describe('typeDemoProgram', () => {
  it('types one line per call, each committed by a SEPARATE newline', async () => {
    const r = recorder();
    await typeDemoProgram({ program: PROGRAM, handle: r.handle, sleep: r.sleep });
    // The ENTER is its own call so it can be followed by a longer settle than
    // the inter-line pace: the guest tokenises the line it just received.
    expect(r.typed.slice(0, 4)).toEqual(['10 MODE 1', '\n', '20 PRINT "HI"', '\n']);
  });

  it('types the run command LAST and WITHOUT a newline — ENTER is the visitor\'s', async () => {
    const r = recorder();
    const done = await typeDemoProgram({ program: PROGRAM, handle: r.handle, sleep: r.sleep });
    expect(done).toBe(true);
    expect(r.typed[r.typed.length - 1]).toBe('RUN');
    expect(r.typed.join('')).not.toMatch(/RUN\n/);
  });

  it('paces the guest with one delay per line', async () => {
    const r = recorder();
    await typeDemoProgram({
      program: PROGRAM, handle: r.handle, sleep: r.sleep,
      delayMs: 42, enterDelayMs: 99, perCharMs: 0,
    });
    expect(r.waits).toEqual([42, 99, 42, 99, 0]);
  });

  it('defaults the pacing to the named constant', async () => {
    const r = recorder();
    await typeDemoProgram({ program: PROGRAM, handle: r.handle, sleep: r.sleep });
    const perLine = PROGRAM.lines.map((l) => Math.max(DEMO_LINE_DELAY_MS, l.length * DEMO_PER_CHAR_MS));
    expect(r.waits).toEqual([
      perLine[0], DEMO_ENTER_DELAY_MS, perLine[1], DEMO_ENTER_DELAY_MS,
      PROGRAM.runCommand.length * DEMO_PER_CHAR_MS,
    ]);
    expect(DEMO_LINE_DELAY_MS).toBeGreaterThan(0);
    // The post-ENTER settle must be the longer of the two, or the next line's
    // first character lands while BASIC is still tokenising and is lost.
    expect(DEMO_ENTER_DELAY_MS).toBeGreaterThan(DEMO_LINE_DELAY_MS);
  });

  it('honours a tile-declared perCharMs over the fleet default', async () => {
    // vic20 paces 80 ms hold + 80 ms gap, so its characters reach the guest at
    // half the fleet default's assumed rate. Waiting the default would submit
    // each line before the previous one finished arriving.
    const slow: DemoProgram = { ...PROGRAM, perCharMs: 170 };
    const r = recorder();
    await typeDemoProgram({ program: slow, handle: r.handle, sleep: r.sleep });
    expect(r.waits[0]).toBe(PROGRAM.lines[0].length * 170);
    expect(r.waits[r.waits.length - 1]).toBe(PROGRAM.runCommand.length * 170);
  });

  it('lets an explicit perCharMs argument override even a tile-declared one', async () => {
    const r = recorder();
    await typeDemoProgram({
      program: { ...PROGRAM, perCharMs: 170 }, handle: r.handle, sleep: r.sleep,
      delayMs: 1, enterDelayMs: 1, perCharMs: 0,
    });
    expect(r.waits).toEqual([1, 1, 1, 1, 0]);
  });

  it('stops mid-listing when cancelled and never sends the run command', async () => {
    const r = recorder();
    const done = await typeDemoProgram({
      program: PROGRAM, handle: r.handle, sleep: r.sleep,
      cancelled: () => r.typed.length >= 1,
    });
    expect(done).toBe(false);
    expect(r.typed).toEqual(['10 MODE 1']);
  });

  it('is content-agnostic: any listing length works', async () => {
    const long: DemoProgram = {
      label: 'x',
      lines: Array.from({ length: 25 }, (_, i) => `${(i + 1) * 10} REM LINE`),
      runCommand: 'RUN',
    };
    const r = recorder();
    await typeDemoProgram({ program: long, handle: r.handle, sleep: r.sleep });
    expect(r.typed).toHaveLength(25 * 2 + 1);
  });
});

describe('registry-declared demo programs', () => {
  it('offers the listing for amstradcpc and nothing for a tile without one', () => {
    const cpc = demoProgramFor('amstradcpc');
    expect(cpc?.label).toBeTruthy();
    expect(cpc?.runCommand.trim()).toBeTruthy();
    expect(cpc?.runCommand).not.toContain('\n');
    expect(cpc?.lines.length).toBeGreaterThan(0);
    // Every line must be its own BASIC statement line — no embedded newlines.
    for (const line of cpc?.lines ?? []) expect(line).not.toContain('\n');
    expect(demoProgramFor('solariscde')).toBeUndefined();
  });

  it('declares only characters typeText can key in (ASCII)', () => {
    const cpc = demoProgramFor('amstradcpc');
    for (const line of cpc?.lines ?? []) expect(line).toMatch(/^[\x20-\x7e]+$/);
    expect(cpc?.runCommand).toMatch(/^[\x20-\x7e]+$/);
  });

  it('rewrites a listing through the guest keyboard, run command included', async () => {
    // The MPF-II puts '=' on Shift+O and '(' on Shift+8 (a PC's Shift+8 is '*').
    const kb = { charMap: { '=': 'O', '(': '*', ')': '(', '*': ')' } } as const;
    const r = recorder();
    await typeDemoProgram({
      program: { label: 'x', lines: ['20 hcolor=int(rnd(1)*8)'], runCommand: 'run(1)' },
      handle: r.handle, sleep: r.sleep, keyboard: kb, perCharMs: 0,
    });
    expect(r.typed[0]).toBe('20 hcolorOint*rnd*1()8(');
    expect(r.typed[r.typed.length - 1]).toBe('run*1(');
  });

  it('sends letters unshifted on an upper-case-only machine', () => {
    // Its shifted letter row is punctuation: typing "PRINT" as Shift+p reached
    // the real MPF-II as "+", so upper case must go down as lower case.
    expect(applyKeyboard('PRINT A$', { letterCase: 'upper-only' })).toBe('print a$');
  });

  it('applies the char map after the case rule, not before', () => {
    // '=' must still translate when it arrives beside down-cased letters.
    const kb = { charMap: { '=': 'O' }, letterCase: 'upper-only' } as const;
    // 'O' is the ESCAPE character here, so a literal 'O' in the listing must not
    // be re-translated into itself twice or the map would be order-sensitive.
    expect(applyKeyboard('A=1', kb)).toBe('aO1');
  });

  it('leaves text untouched when a tile declares no keyboard', () => {
    expect(applyKeyboard('10 hcolor=3', undefined)).toBe('10 hcolor=3');
  });

  it('mpf2 declares a keyboard covering every character its layout moves', () => {
    const p = demoProgramFor('mpf2');
    const kb = keyboardFor('mpf2');
    expect(p).toBeDefined();
    expect(kb).toBeDefined();
    const listing = [...p!.lines, p!.runCommand].join('');
    for (const ch of '=-+()*') {
      if (listing.includes(ch)) expect(kb!.charMap?.[ch]).toBeDefined();
    }
  });
});
