import type { KeyChord, KeywordTable } from '../../types';
import { keywordTableFor } from '../../data/keywordKeys';

// ---------------------------------------------------------------------------
//  keywordEntry — the KEYWORD TRANSCODER: an ASCII BASIC listing → the key
//  chords that enter it on a keyword-entry machine (48K Spectrum, ZX81).
//
//  On these machines one key IS a keyword: P with the K cursor gives PRINT.
//  ASCII typed letter by letter is garbage there (`10 PRINT "Hi"` became
//  `10 PRINT rint hi` on the Spectrum), so the line is tokenised greedily
//  against the station's key table (data/keywordKeys.ts, generated from the
//  station's own keymap) while TRACKING THE CURSOR MODE THE ROM WILL BE IN:
//
//   - K at the start of a statement: after the line number, after THEN, and on
//     the Spectrum after a ':' outside quotes (its ROM's OUT-CHAR rule, digits
//     and spaces leave the mode alone). There a statement keyword is ONE key.
//   - L everywhere else: letters are letters, and a keyword or symbol is a
//     shift chord (SYMBOL SHIFT / SHIFT) or an E / FUNCTION mode prefix + key.
//   - literal text inside quotes and after REM. The Spectrum's ROM still reads
//     ':' in a REM as a statement start, so a letter right after one would
//     come out as a keyword: that is reported, not typed (measured on a rig).
//
//  Spaces between tokens are dropped (the ROM prints its own); spaces inside
//  strings and REM are kept, except the one straight after REM, which the ROM
//  prints itself. Anything with no key, or a statement keyword where the
//  cursor cannot be K, is an ISSUE: the editor shows it and refuses to type,
//  never a silent drop.
// ---------------------------------------------------------------------------

export interface KeywordIssue {
  /** 0-based column in the visitor's line. */
  readonly at: number;
  readonly text: string;
  readonly why: string;
}

export interface TranscodedLine {
  readonly chords: readonly KeyChord[];
  readonly issues: readonly KeywordIssue[];
}

interface Matcher {
  /** The table's spelling (what the ROM lists). */
  readonly token: string;
  readonly re: RegExp;
  readonly chords: readonly KeyChord[];
  /** One key, only where the cursor is K. */
  readonly statement: boolean;
}

export interface KeywordMachine {
  readonly table: KeywordTable;
  /** Machine name for the visitor's messages. */
  readonly name: string;
  /** Spectrum: ':' separates statements (K), and the ROM applies it inside REM too. */
  readonly colonStatements: boolean;
  readonly words: readonly Matcher[];
  readonly symbols: readonly Matcher[];
}

const LETTER = /[A-Za-z]/;
const ALNUM = /[A-Za-z0-9]/;
const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** `GO TO` matches GOTO and GO TO; `OPEN #` matches OPEN#. Sticky, case-insensitive. */
function wordPattern(spelling: string): RegExp {
  const parts = spelling.split(/ +/).map(escape);
  return new RegExp(parts.join(' *').replace(/ \*#/g, ' *#'), 'iy');
}

const MACHINES = new Map<KeywordTable, KeywordMachine>();

function keywordMachine(table: KeywordTable): KeywordMachine {
  let machine = MACHINES.get(table);
  if (machine) return machine;
  const words: Matcher[] = [];
  const symbols: Matcher[] = [];
  const add = (spelling: string, token: string) => {
    const statement = token in table.statements;
    const chords = statement ? table.statements[token] : table.tokens[token];
    if (!chords) return;
    if (LETTER.test(spelling[0])) words.push({ token, re: wordPattern(spelling), chords, statement });
    else symbols.push({ token, re: new RegExp(escape(spelling), 'y'), chords, statement });
  };
  for (const token of [...Object.keys(table.statements), ...Object.keys(table.tokens)]) add(token, token);
  for (const [spelling, token] of Object.entries(table.aliases)) add(spelling, token);
  // Greedy: the longest spelling wins (INPUT over IN, <= over <, ** over *).
  const longestFirst = (a: Matcher, b: Matcher) => b.re.source.length - a.re.source.length;
  words.sort(longestFirst);
  symbols.sort(longestFirst);
  const spectrum = table.dialect === 'sinclair-basic';
  machine = { table, name: spectrum ? 'the Spectrum' : 'the ZX81', colonStatements: spectrum, words, symbols };
  MACHINES.set(table, machine);
  return machine;
}

/** The transcoder for a station, when its dialect is keyword entry. */
export function keywordMachineFor(osId: string): KeywordMachine | undefined {
  const table = keywordTableFor(osId);
  return table ? keywordMachine(table) : undefined;
}

function matchAt(list: readonly Matcher[], line: string, at: number, wholeWord: boolean): { m: Matcher; end: number } | null {
  for (const m of list) {
    m.re.lastIndex = at;
    if (!m.re.test(line)) continue;
    const end = m.re.lastIndex;
    // A keyword ending in a letter must not run on into an identifier.
    if (wholeWord && ALNUM.test(line[end - 1]) && end < line.length && ALNUM.test(line[end])) continue;
    return { m, end };
  }
  return null;
}

/** Transcode one listing line into chords (ENTER not included). */
export function transcodeLine(line: string, machine: KeywordMachine): TranscodedLine {
  const { table } = machine;
  const chords: KeyChord[] = [];
  const issues: KeywordIssue[] = [];
  const quote = table.tokens['"'];
  let mode: 'K' | 'L' = 'K';
  let ctx: 'code' | 'string' | 'rem' = 'code';
  let quoted = false; // the Spectrum ROM's quote flag, which it keeps inside REM too
  let ident = false; // inside an identifier: no keyword starts here
  // A literal character: a plain key, or a one-character symbol chord.
  const literal = (ch: string) => table.chars[ch] ?? (ch.length === 1 && !LETTER.test(ch) ? table.tokens[ch] : undefined);
  const noKey = (at: number, ch: string) =>
    issues.push({ at, text: ch, why: `${machine.name} has no key for “${ch}”` });

  let i = 0;
  while (i < line.length) {
    const ch = line[i];
    if (ctx === 'string') {
      if (ch === '"') {
        const escaped = line[i + 1] === '"' ? table.tokens['""'] : undefined;
        if (escaped) { chords.push(...escaped); i += 2; continue; }
        chords.push(...quote);
        ctx = 'code';
        mode = 'L';
      } else {
        const keys = literal(ch);
        if (keys) chords.push(...keys); else noKey(i, ch);
      }
      i += 1;
      continue;
    }
    if (ctx === 'rem') {
      if (machine.colonStatements && mode === 'K' && LETTER.test(ch)) {
        issues.push({ at: i, text: ch, why: `after “:” ${machine.name} reads a letter as a keyword, even in a REM` });
      } else {
        const keys = literal(ch);
        if (keys) chords.push(...keys); else noKey(i, ch);
      }
      if (machine.colonStatements) {
        if (ch === '"') quoted = !quoted;
        if (ch === ':' && !quoted) mode = 'K';
        else if (!/[0-9 ]/.test(ch)) mode = 'L';
      }
      i += 1;
      continue;
    }
    // ---- code ----
    if (ch === ' ') { ident = false; i += 1; continue; }
    if (ch === '"') {
      chords.push(...quote);
      ctx = 'string';
      quoted = true;
      mode = 'L';
      ident = false;
      i += 1;
      continue;
    }
    if (/[0-9]/.test(ch)) {
      // Digits leave the cursor mode alone (a line number keeps K).
      chords.push(...table.chars[ch]);
      i += 1;
      continue;
    }
    if (LETTER.test(ch)) {
      // In K mode every letter key is a keyword, so the longest one wins
      // outright; in L mode only a whole word is a keyword (`total` is not TO).
      const hit = ident ? null : matchAt(machine.words, line, i, mode === 'L');
      if (hit) {
        const { m, end } = hit;
        if (m.statement && mode !== 'K') {
          issues.push({ at: i, text: line.slice(i, end), why: `${m.token} can only start a statement on ${machine.name}` });
        } else chords.push(...m.chords);
        i = end;
        ident = false;
        mode = m.token === 'THEN' ? 'K' : 'L';
        if (m.token === 'REM') {
          ctx = 'rem';
          quoted = false;
          if (line[i] === ' ') i += 1;
        }
        continue;
      }
      if (mode === 'K') {
        const word = /^[A-Za-z0-9$]+/.exec(line.slice(i))?.[0] ?? ch;
        issues.push({ at: i, text: word, why: `a statement on ${machine.name} must start with a keyword (LET for an assignment)` });
        i += word.length;
        continue;
      }
      chords.push(...table.chars[ch]);
      ident = true;
      i += 1;
      continue;
    }
    const sym = matchAt(machine.symbols, line, i, false);
    if (sym) {
      chords.push(...sym.m.chords);
      mode = machine.colonStatements && sym.m.token === ':' ? 'K' : 'L';
      ident = false;
      i = sym.end;
      continue;
    }
    // A plain key that is not a letter or digit (the ZX81's own '.').
    const plain = table.chars[ch];
    if (plain) { chords.push(...plain); mode = 'L'; } else noKey(i, ch);
    ident = false;
    i += 1;
  }
  return { chords, issues };
}
