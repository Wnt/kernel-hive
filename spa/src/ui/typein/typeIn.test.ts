import { describe, expect, it } from 'vitest';
import { dialectSpec } from './basicDialects';
import {
  applyCase, checkListing, cleanListing, estimateMs, foldToAscii, formatDuration, linesToType, withClearFirst,
} from './listingText';
import { abortableSleep, paceFor, prepareFor, typeListing } from './typeInRun';
import { typeInFor } from '../../data/demoPrograms';
import { keyboardFor } from '../../data/keyboards';
import { DEMO_ENTER_DELAY_MS, DEMO_LINE_DELAY_MS } from '../grid/StreamView/typeDemoProgram';
import type { TypeInConfig } from '../../types';

const cbm = dialectSpec('cbm-basic');
const msx = dialectSpec('msx-basic');

describe('cleanListing / linesToType', () => {
  it('normalises line ends, tabs, trailing blanks and a BOM, and keeps every character', () => {
    expect(cleanListing('﻿10 PRINT "A"  \r\n20\tGOTO 10\r30 END\n\n')).toBe('10 PRINT "A"\n20 GOTO 10\n30 END');
    expect(cleanListing('10 PRINT “Ä”')).toBe('10 PRINT “Ä”');
  });

  it('types no blank lines', () => {
    expect(linesToType('10 A=1\n\n   \n20 B=2\n')).toEqual(['10 A=1', '20 B=2']);
  });
});

describe('checkListing', () => {
  it('names every character the machine cannot receive, and the lines holding them', () => {
    const check = checkListing('10 PRINT “HI”\n20 A=1\n30 PRINT "£"', {}, cbm);
    expect(check.bad).toEqual(['“', '”', '£']);
    expect(check.badLines).toEqual([1, 3]);
    // Curly quotes have an exact ASCII meaning; a pound sign does not.
    expect(check.foldable).toBe(2);
  });

  it('flags lines past the machine line limit, and magazine control codes', () => {
    const long = `10 PRINT "${'X'.repeat(90)}"`;
    const check = checkListing(`${long}\n20 PRINT "{CLR}"`, { maxLineChars: 88 }, cbm);
    expect(check.longLines).toEqual([1]);
    expect(check.braceLines).toEqual([2]);
    expect(check.bad).toEqual([]);
  });

  it('folds typographic characters to ASCII and nothing else', () => {
    expect(foldToAscii('10 PRINT “IT’S” – OK…  π')).toEqual({ text: '10 PRINT "IT\'S" - OK...  π', changed: 5 });
  });
});

describe('withClearFirst — a run never merges with the program in memory', () => {
  it('puts the dialect clear command (NEW) in front', () => {
    expect(cbm.clearCommand).toBe('NEW');
    expect(withClearFirst(['10 A=1'], cbm, true)).toEqual(['NEW', '10 A=1']);
  });

  it('never doubles it, and stays out of the way when off or empty', () => {
    expect(withClearFirst(['new', '10 A=1'], cbm, true)).toEqual(['new', '10 A=1']);
    expect(withClearFirst(['10 A=1'], cbm, false)).toEqual(['10 A=1']);
    expect(withClearFirst([], cbm, true)).toEqual([]);
  });

  it('every dialect has one', () => {
    for (const d of ['cbm-basic', 'bbc-basic', 'msx-basic', 'locomotive-basic', 'superbasic', 'sam-basic',
      'oric-basic', 'color-basic', 'applesoft'] as const) expect(dialectSpec(d).clearCommand).toBe('NEW');
  });
});

describe('applyCase — the station case rule', () => {
  it('unshifted: every letter goes down unshifted (caps lock on / no lower case)', () => {
    expect(applyCase('10 PRINT "Hi"', 'unshifted', cbm)).toBe('10 print "hi"');
  });

  it('code-lower: keywords unshifted, the visitor\'s literals untouched (CBM business mode)', () => {
    expect(applyCase('10 PRINT "Hi":REM Keep', 'code-lower', cbm)).toBe('10 print "Hi":rem Keep');
    expect(applyCase('20 DATA Ab,Cd:GOTO 10', 'code-lower', cbm)).toBe('20 data Ab,Cd:goto 10');
  });

  it("code-upper: keywords up, strings and ' comments kept (MSX)", () => {
    expect(applyCase("10 print \"Hi\" ' note", 'code-upper', msx)).toBe("10 PRINT \"Hi\" ' note");
  });

  it('as-typed (or absent): unchanged', () => {
    expect(applyCase('10 Print', 'as-typed', cbm)).toBe('10 Print');
    expect(applyCase('10 Print', undefined, cbm)).toBe('10 Print');
  });
});

describe('estimate', () => {
  it('prices each line by the station pace', () => {
    expect(estimateMs([2, 1], { perCharMs: 100, lineDelayMs: 10, enterDelayMs: () => 1 })).toBe(3 * 100 + 2 * 11);
    expect(estimateMs([1, 1], { perCharMs: 0, lineDelayMs: 0, enterDelayMs: (i) => 10 * (i + 1) })).toBe(30);
    expect(formatDuration(42_000)).toBe('42 s');
    expect(formatDuration(100_000)).toBe('1 min 40 s');
  });
});

// A handle that records every key call, with a connection that can drop.
function recorder() {
  const keys: string[] = [];
  const waits: number[] = [];
  let connected = true;
  return {
    keys,
    waits,
    drop: () => { connected = false; },
    handle: { typeText: (t: string) => { keys.push(t); }, isConnected: () => connected },
    sleep: async (ms: number) => { waits.push(ms); },
  };
}

describe('typeListing — the editor typist', () => {
  it('takes its pace from the station registry, not a constant', async () => {
    const config = typeInFor('vic20')!;
    expect(config.perCharMs).toBeGreaterThanOrEqual(120); // vic20 drains at 60 + 60
    const r = recorder();
    const outcome = await typeListing({
      osId: 'vic20', config, spec: cbm, lines: ['10 PRINT "HI"'], handle: r.handle,
      signal: new AbortController().signal, sleep: r.sleep,
    });
    expect(outcome).toBe('done');
    const chars = '10 PRINT "HI"'.length;
    expect(r.waits).toEqual([
      ...Array(chars).fill(config.perCharMs),
      config.lineDelayMs ?? DEMO_LINE_DELAY_MS,
      config.enterDelayMs ?? DEMO_ENTER_DELAY_MS,
    ]);
  });

  it('keys one character per call, through the case rule and the station keyboard', async () => {
    const r = recorder();
    await typeListing({
      osId: 'vic20', config: typeInFor('vic20')!, spec: cbm, lines: ['10 PRINT "HI"'], handle: r.handle,
      signal: new AbortController().signal, sleep: r.sleep,
    });
    // A VIC-20 listing is printed in capitals; Shift+letter there is a graphics glyph.
    expect(r.keys.every((k) => k.length === 1)).toBe(true);
    expect(r.keys.join('')).toBe('10 print "hi"\n');
  });

  it('applies the charMap after the case rule (MPF-II puts = on Shift+O)', () => {
    const prepare = prepareFor('mpf2', typeInFor('mpf2')!, dialectSpec('applesoft'));
    expect(keyboardFor('mpf2')?.charMap?.['=']).toBe('O');
    expect(prepare('20 HCOLOR=3')).toBe('20 hcolorO3');
  });

  it('reports progress line by line and character by character', async () => {
    const r = recorder();
    const seen: string[] = [];
    await typeListing({
      osId: 'vic20', config: typeInFor('vic20')!, spec: cbm, lines: ['10 A', '20 B'], handle: r.handle,
      signal: new AbortController().signal, sleep: r.sleep,
      onProgress: (p) => seen.push(`${p.line}/${p.lines}:${p.chars}/${p.totalChars}`),
    });
    expect(seen[0]).toBe('1/2:0/8');
    expect(seen).toContain('2/2:4/8');
    expect(seen[seen.length - 1]).toBe('2/2:8/8');
  });

  it('Stop: no key leaves after the abort, even mid-line', async () => {
    const r = recorder();
    const abort = new AbortController();
    const outcome = await typeListing({
      osId: 'vic20', config: typeInFor('vic20')!, spec: cbm, lines: ['10 PRINT 1', '20 PRINT 2'], handle: r.handle,
      signal: abort.signal,
      sleep: async (ms) => { r.waits.push(ms); if (r.keys.length === 4) abort.abort(); },
    });
    expect(outcome).toBe('stopped');
    expect(r.keys).toEqual(['1', '0', ' ', 'p']);
  });

  it('a dropped stream stops the run and says so', async () => {
    const r = recorder();
    const outcome = await typeListing({
      osId: 'vic20', config: typeInFor('vic20')!, spec: cbm, lines: ['10 A', '20 B'], handle: r.handle,
      signal: new AbortController().signal,
      sleep: async () => { if (r.keys.length === 2) r.drop(); },
    });
    expect(outcome).toBe('disconnected');
    expect(r.keys).toEqual(['1', '0']);
  });

  it('abortableSleep ends at once when stopped, so Stop never sits out a settle', async () => {
    const abort = new AbortController();
    const t0 = Date.now();
    const pending = abortableSleep(abort.signal)(60_000);
    abort.abort();
    await pending;
    expect(Date.now() - t0).toBeLessThan(1000);
    await abortableSleep(abort.signal)(60_000); // already aborted: resolves immediately
  });
});

describe('typeIn.wrapPause — the typist waits at the screen wrap', () => {
  const base: TypeInConfig = { dialect: 'applesoft', perCharMs: 70, lineDelayMs: 200, enterDelayMs: 500 };
  const run = async (config: TypeInConfig, lines: string[]) => {
    const r = recorder();
    const trace: string[] = []; // keys and waits, in order
    const handle = { ...r.handle, typeText: (t: string) => { trace.push(`k${t === '\n' ? 'N' : t}`); } };
    await typeListing({
      osId: 'x', config, spec: dialectSpec('applesoft'), lines, handle, signal: new AbortController().signal,
      sleep: async (ms) => { trace.push(`w${ms}`); },
    });
    return trace;
  };

  it('adds ms after exactly every cols-th character, several wraps in one line', async () => {
    const trace = await run({ ...base, wrapPause: { cols: 4, ms: 900 } }, ['aaaaaaaaaa']); // 10 chars
    const waits = trace.filter((t) => t[0] === 'w').map((t) => Number(t.slice(1)));
    // chars 1..10: 70 each, 970 after the 4th and 8th; line delay 200, settle 500.
    expect(waits).toEqual([70, 70, 70, 970, 70, 70, 70, 970, 70, 70, 200, 500]);
  });

  it('restarts the count on every line, and skips a line that ends on the wrap', async () => {
    const trace = await run({ ...base, wrapPause: { cols: 4, ms: 900 } }, ['aaaa', 'aaaaa']);
    const waits = trace.filter((t) => t[0] === 'w').map((t) => Number(t.slice(1)));
    expect(waits).toEqual([70, 70, 70, 70, 200, 500, 70, 70, 70, 970, 70, 200, 500]);
  });

  it('promptCols moves the first wrap sooner (the prompt owns column 0), the later ones every cols', async () => {
    const trace = await run({ ...base, wrapPause: { cols: 4, ms: 900, promptCols: 1 } }, ['aaaaaaaaaa']);
    const waits = trace.filter((t) => t[0] === 'w').map((t) => Number(t.slice(1)));
    // wraps after chars 3 and 7 (3 + 1 prompt = 4, 7 + 1 = 8)
    expect(waits).toEqual([70, 70, 970, 70, 70, 70, 970, 70, 70, 70, 200, 500]);
  });

  it('adds no pause when the field is absent', async () => {
    const trace = await run(base, ['aaaaaaaaaa']);
    const waits = trace.filter((t) => t[0] === 'w').map((t) => Number(t.slice(1)));
    expect(Math.max(...waits)).toBe(500);
    expect(waits.slice(0, 10).every((w) => w === 70)).toBe(true);
  });

  it('paceFor carries it from the registry', () => {
    expect(paceFor({ ...base, wrapPause: { cols: 40, ms: 1 } }, []).wrapPause).toEqual({ cols: 40, ms: 1 });
    expect(paceFor(base, []).wrapPause).toBeUndefined();
  });
});

describe('station-specific traps (registry typeIn)', () => {
  const sam = dialectSpec('sam-basic');

  it('settles longer after a named direct command — SAM NEW redraws the banner and eats the next key', () => {
    const config = typeInFor('samcoupe')!;
    const pace = paceFor(config, ['NEW', '10 MODE 4', 'new']);
    expect(pace.enterDelayMs(0)).toBeGreaterThanOrEqual(1500);
    expect(pace.enterDelayMs(1)).toBe(config.enterDelayMs ?? DEMO_ENTER_DELAY_MS);
    expect(pace.enterDelayMs(2)).toBe(pace.enterDelayMs(0)); // matched case-insensitively
  });

  it('the run actually waits that settle after NEW before the next line', async () => {
    const r = recorder();
    await typeListing({
      osId: 'samcoupe', config: typeInFor('samcoupe')!, spec: sam, lines: ['NEW', '10 CLS'], handle: r.handle,
      signal: new AbortController().signal, sleep: r.sleep,
    });
    const enter = r.keys.indexOf('\n');
    expect(r.keys[enter + 1]).toBe('1');
    expect(Math.max(...r.waits)).toBe(typeInFor('samcoupe')!.settleAfter!.NEW);
  });

  it('flags symbols the station keymap cannot reach, and never types them', () => {
    const config = typeInFor('samcoupe')!;
    expect(config.unreachable).toContain('<');
    const check = checkListing('10 IF a<b THEN PRINT "[x]"', config, sam);
    expect(check.bad).toEqual(['<', '[', ']']);
    expect(check.foldable).toBe(0);
    expect(checkListing('10 IF a<b THEN STOP', typeInFor('amstradcpc')!, sam).bad).toEqual([]);
  });
});

describe('registry typeIn data', () => {
  it('mpf2 pauses at the screen wrap, declared as data', () => {
    expect(typeInFor('mpf2')!.wrapPause).toEqual({ cols: 40, ms: 500, promptCols: 1 });
    expect(typeInFor('vic20')!.wrapPause).toBeUndefined();
  });

  it('gives every editor station a declared pace and a dialect', () => {
    for (const id of ['vic20', 'pet2001', 'cbm8032', 'c128', 'plus4', 'cbm2', 'bbcmicro', 'armeval', 'dragon32',
      'oricatmos', 'msx2', 'svi728', 'svi328', 'amstradcpc', 'mpf2', 'sinclairql', 'samcoupe', 'zxspectrum', 'zx81']) {
      const config: TypeInConfig | undefined = typeInFor(id);
      expect(config, id).toBeDefined();
      expect(paceFor(config!, []).perCharMs).toBe(config!.perCharMs);
    }
  });

  it('sends keyword-entry machines through the transcoder: letters typed one by one are not keywords there', () => {
    // On a 48K Spectrum or a ZX81 one key IS a keyword (P gives PRINT), so an
    // ASCII listing typed letter by letter would arrive as garbage.
    expect(typeInFor('zxspectrum')?.dialect).toBe('sinclair-basic');
    expect(typeInFor('zx81')?.dialect).toBe('zx81-basic');
    expect(typeInFor('zx81')?.case).toBeUndefined();
  });
});
