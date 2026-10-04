import { describe, expect, it } from 'vitest';
import { keywordMachineFor, transcodeLine, type KeywordMachine } from './keywordEntry';
import { checkListing, isNewCommand } from './listingText';
import { dialectSpec } from './basicDialects';
import { markBad, highlightLine } from './basicHighlight';
import { paceFor, typeListing } from './typeInRun';
import { demoProgramFor, typeInFor } from '../../data/demoPrograms';
import { typeDemoProgram } from '../grid/StreamView/typeDemoProgram';
import type { KeyChord } from '../../types';

// Scancodes as the station keymaps map them (set1, US positions).
const CAPS = 0x2a, SYM = 0x36, SHIFT = 0x2a, ENTER = 0x1c;
const E = [CAPS, SYM]; // the Spectrum's extended mode
const FN = [SHIFT, ENTER]; // the ZX81's FUNCTION mode
const k = (ch: string): number => {
  const rows = ['1234567890', 'qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  const base = [0x02, 0x10, 0x1e, 0x2c];
  for (const [r, row] of rows.entries()) if (row.includes(ch)) return base[r] + row.indexOf(ch);
  throw new Error(ch);
};
const keys = (s: string): KeyChord[] => [...s].map((ch) => [k(ch)]);

const spectrum = keywordMachineFor('zxspectrum') as KeywordMachine;
const zx81 = keywordMachineFor('zx81') as KeywordMachine;
const chords = (line: string, m: KeywordMachine) => {
  const out = transcodeLine(line, m);
  expect(out.issues, line).toEqual([]);
  return out.chords;
};
const issues = (line: string, m: KeywordMachine) => transcodeLine(line, m).issues.map((i) => `${i.at}:${i.text}`);

describe('keyword transcoder — 48K Spectrum', () => {
  it('types the chords proven on a rig for `10 PRINT "Hi"` / `20 INK 2: CIRCLE 128,88,40`', () => {
    expect(chords('10 PRINT "Hi"', spectrum)).toEqual([
      ...keys('10p'), [SYM, k('p')], [CAPS, k('h')], [k('i')], [SYM, k('p')],
    ]);
    expect(chords('20 INK 2: CIRCLE 128,88,40', spectrum)).toEqual([
      ...keys('20'), E, [SYM, k('x')], [k('2')], [SYM, k('z')], E, [SYM, k('h')],
      ...keys('128'), [SYM, k('n')], ...keys('88'), [SYM, k('n')], ...keys('40'),
    ]);
  });

  it('puts the cursor back in K after THEN and after a colon', () => {
    expect(chords('10 IF a THEN PRINT 1', spectrum)).toEqual([
      ...keys('10u'), [k('a')], [SYM, k('g')], [k('p')], [k('1')],
    ]);
    expect(chords('10 CLS: BORDER 1', spectrum)).toEqual([...keys('10v'), [SYM, k('z')], ...keys('b1')]);
  });

  it('matches keywords case-insensitively, in their ROM and ASCII spellings', () => {
    expect(chords('10 GOTO 10', spectrum)).toEqual(chords('10 GO TO 10', spectrum));
    expect(chords('10 go sub 10', spectrum)).toEqual(keys('10h10'));
    expect(chords('10 RAND', spectrum)).toEqual(chords('10 RANDOMIZE', spectrum));
    expect(chords('10 PRINT POINT (1,2)', spectrum).slice(3, 5)).toEqual([E, [SYM, k('8')]]);
  });

  it('keeps identifiers as letters: `total` is not TO, and letter case is CAPS SHIFT', () => {
    expect(chords('10 LET total=1', spectrum)).toEqual([...keys('10l'), ...keys('total'), [SYM, k('l')], [k('1')]]);
    expect(chords('10 LET Ab=1', spectrum).slice(3, 5)).toEqual([[CAPS, k('a')], [k('b')]]);
  });

  it('types two-character operators as their one token, and E-mode symbols', () => {
    expect(chords('10 IF a<=b THEN STOP', spectrum).slice(4, 5)).toEqual([[SYM, k('q')]]);
    expect(chords('10 PRINT "[~]"', spectrum).slice(4, 10)).toEqual([
      E, [SYM, k('y')], E, [SYM, k('a')], E, [SYM, k('u')],
    ]);
  });

  it('keeps strings and REM literal, dropping only the spaces the ROM prints itself', () => {
    expect(chords('10 PRINT  "a b"', spectrum)).toEqual([
      ...keys('10p'), [SYM, k('p')], [k('a')], [0x39], [k('b')], [SYM, k('p')],
    ]);
    expect(chords('10 REM to do', spectrum)).toEqual([...keys('10e'), ...keys('to'), [0x39], ...keys('do')]);
  });

  it('reports, never drops: a statement keyword mid-statement, a missing LET, a backtick', () => {
    expect(issues('10 LET a=PRINT', spectrum)).toEqual(['9:PRINT']);
    expect(issues('10 a=1', spectrum)).toEqual(['3:a']);
    expect(issues('10 PRINT "`"', spectrum)).toEqual(['10:`']);
  });

  it('reports a letter after ":" in a REM — the ROM reads it as a keyword (rig: `REM a: BORDER`)', () => {
    expect(issues('10 REM a:b', spectrum)).toEqual(['9:b']);
    expect(issues('10 REM a: 1', spectrum)).toEqual([]);
    expect(issues('10 REM "a:b"', spectrum)).toEqual([]);
  });
});

describe('keyword transcoder — ZX81', () => {
  it('types the chords proven on a rig for `10 PRINT "HI"` / `20 PRINT INT (RND*9)`', () => {
    expect(chords('10 PRINT "HI"', zx81)).toEqual([...keys('10p'), [SHIFT, k('p')], ...keys('hi'), [SHIFT, k('p')]]);
    expect(chords('20 PRINT INT (RND*9)', zx81)).toEqual([
      ...keys('20p'), FN, [k('r')], [SHIFT, k('i')], FN, [k('t')], [SHIFT, k('b')], [k('9')], [SHIFT, k('o')],
    ]);
  });

  it('has no lower case: every letter is the bare key', () => {
    expect(chords('10 print "hi"', zx81)).toEqual(chords('10 PRINT "HI"', zx81));
  });

  it('knows its own tokens: "" in a string, **, AT, the comma on the . key, K after THEN', () => {
    expect(chords('10 PRINT "A""B"', zx81).slice(3)).toEqual([[SHIFT, k('p')], [k('a')], [SHIFT, k('q')], [k('b')], [SHIFT, k('p')]]);
    expect(chords('10 LET A=2**3', zx81).slice(5)).toEqual([[k('2')], [SHIFT, k('h')], [k('3')]]);
    expect(chords('10 PRINT AT 1,2;0.5', zx81).slice(3)).toEqual([
      FN, [k('c')], [k('1')], [SHIFT, 0x34], [k('2')], [SHIFT, k('x')], [k('0')], [0x34], [k('5')],
    ]);
    expect(chords('10 IF A=1 THEN GOTO 10', zx81).slice(6, 8)).toEqual([[SHIFT, k('3')], [k('g')]]);
  });

  it('has no statement separator: a colon is a character, even in a REM', () => {
    expect(issues('10 REM A:B', zx81)).toEqual([]);
  });

  it('reports what the ZX81 has no key for', () => {
    expect(issues('10 PRINT "HI!"', zx81)).toEqual(['12:!']);
    expect(issues('10 PRINT A^2', zx81)).toEqual(['10:^']);
  });
});

describe('the editor around the transcoder', () => {
  const spec = dialectSpec('sinclair-basic');

  it('lists the issues by editor line and counts chords for the estimate', () => {
    const check = checkListing('10 PRINT "Hi"\n\n20 a=1', {}, spec, spectrum);
    expect(check.keywordIssues.map((i) => `${i.line}:${i.text}`)).toEqual(['3:a']);
    expect(check.keystrokes).toEqual([7, 4]); // typing goes on past an issue: 2 0 = 1
  });

  it('highlights from the key table, and paints an issue red', () => {
    expect(spec.keywords.has('CIRCLE') && spec.keywords.has('GO')).toBe(true);
    const painted = markBad(highlightLine('20 a=1', spec), [{ at: 3, len: 1 }]);
    expect(painted.find((t) => t.kind === 'bad')?.text).toBe('a');
    expect(painted.map((t) => t.text).join('')).toBe('20 a=1');
  });

  it('types chords, one per call, at the station pace, with the NEW settle', async () => {
    const config = typeInFor('zxspectrum')!;
    expect(config.dialect).toBe('sinclair-basic');
    const sent: KeyChord[] = [];
    const text: string[] = [];
    const waits: number[] = [];
    const outcome = await typeListing({
      osId: 'zxspectrum', config, spec, keywords: spectrum, lines: ['NEW', '10 PRINT "Hi"'],
      handle: { typeText: (t) => { text.push(t); }, typeChord: (c) => { sent.push(c); }, isConnected: () => true },
      signal: new AbortController().signal, sleep: async (ms) => { waits.push(ms); },
    });
    expect(outcome).toBe('done');
    expect(sent).toEqual([[k('a')], ...chords('10 PRINT "Hi"', spectrum)]);
    expect(text).toEqual(['\n', '\n']); // ENTER, one per line
    expect(waits[0]).toBe(config.perCharMs);
    expect(waits[2]).toBe(config.newDelayMs);
    const pace = paceFor(config, ['NEW', 'x']);
    expect(pace.enterDelayMs(0)).toBe(config.newDelayMs);
    expect(pace.enterDelayMs(1)).toBe(config.enterDelayMs ?? 600);
    expect(isNewCommand(' new ')).toBe(true);
  });

  it('grows the ZX81 settle with the listing: its 1 KB display is rebuilt after every ENTER', () => {
    const config = typeInFor('zx81')!;
    const pace = paceFor(config, ['NEW', '10 PRINT 1', '20 PRINT 2']);
    expect(config.enterDelayPerLineMs).toBeGreaterThan(0);
    expect(pace.enterDelayMs(2) - pace.enterDelayMs(1)).toBe(config.enterDelayPerLineMs);
    expect(pace.enterDelayMs(1)).toBe((config.enterDelayMs ?? 600) + (config.enterDelayPerLineMs ?? 0));
  });

  it('types the Spectrum demo listing (plain ASCII) as chords, and its RUN as one key with no ENTER', async () => {
    const demo = demoProgramFor('zxspectrum')!;
    for (const line of demo.lines) expect(transcodeLine(line, spectrum).issues, line).toEqual([]);
    const sent: KeyChord[] = [];
    const text: string[] = [];
    await typeDemoProgram({
      program: demo,
      handle: { typeText: (t) => { text.push(t); }, typeChord: (c) => { sent.push(c); } },
      chords: (line) => transcodeLine(line, spectrum).chords,
      sleep: async () => {},
    });
    expect(sent.slice(0, 4)).toEqual(keys('10b1'));
    expect(sent[sent.length - 1]).toEqual([k('r')]);
    expect(text).toEqual(demo.lines.map(() => '\n')); // ENTER per line, none after RUN
  });
});
