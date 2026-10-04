import type { TypeInCase, TypeInConfig } from '../../types';
import type { DialectSpec } from './basicDialects';
import { isTypable } from './basicHighlight';
import { transcodeLine, type KeywordIssue, type KeywordMachine } from './keywordEntry';

// ---------------------------------------------------------------------------
//  listingText — what the editor holds versus what the typist keys.
//
//  The editor shows the visitor's text as they gave it (a curly quote stays a
//  curly quote, so they can SEE it); the typist keys `linesToType()` of it.
//  Nothing is dropped silently: a character the machine cannot receive is an
//  issue that blocks typing until the visitor fixes it, or lets
//  `foldToAscii()` swap the typographic ones a web page or PDF smuggles in.
// ---------------------------------------------------------------------------

/** What a paste, a file or an example becomes in the editor: LF line ends,
 *  tabs as spaces, no trailing blanks or BOM. Characters are NOT changed. */
export function cleanListing(text: string): string {
  return text
    .replace(/^\ufeff/, '')
    .replace(/\r\n?/g, '\n')
    .replace(/\t/g, ' ')
    .split('\n')
    .map((line) => line.replace(/[ ]+$/, ''))
    .join('\n')
    .replace(/\n+$/, '');
}

/** The lines the typist sends: cleaned, blank lines skipped (a bare ENTER at a
 *  BASIC prompt does nothing but cost a settle). */
export function linesToType(text: string): string[] {
  return cleanListing(text).split('\n').filter((line) => line.trim().length > 0);
}

/** A line that is just NEW: the machine clears (and may re-test) its memory and
 *  ignores the keyboard meanwhile, hence `typeIn.newDelayMs`. */
export function isNewCommand(line: string): boolean {
  return /^\s*new\s*$/i.test(line);
}

// Typographic look-alikes with an exact ASCII meaning. Anything not here
// (accented letters, £, π, block graphics) stays an issue: guessing would put
// a different program into the machine.
const FOLDS: Record<string, string> = {
  '\u2018': "'", '\u2019': "'", '\u201a': "'", '\u201b': "'", '\u2032': "'",
  '\u201c': '"', '\u201d': '"', '\u201e': '"', '\u201f': '"', '\u2033': '"',
  '\u2010': '-', '\u2011': '-', '\u2012': '-', '\u2013': '-', '\u2014': '-', '\u2212': '-',
  '\u2026': '...', '\u00a0': ' ', '\u2009': ' ', '\u202f': ' ', '\u2002': ' ', '\u2003': ' ',
  '\u00d7': '*', '\u00f7': '/', '\u2191': '^',
};

export function foldToAscii(text: string): { text: string; changed: number } {
  let changed = 0;
  let out = '';
  for (const ch of text) {
    const fold = FOLDS[ch];
    if (fold !== undefined) { changed += 1; out += fold; } else out += ch;
  }
  return { text: out, changed };
}

export interface ListingCheck {
  /** Distinct characters the machine cannot receive, in order of appearance. */
  readonly bad: readonly string[];
  /** How many of those foldToAscii() can replace. */
  readonly foldable: number;
  /** 1-based editor lines holding a bad character. */
  readonly badLines: readonly number[];
  /** 1-based editor lines longer than the machine's line. */
  readonly longLines: readonly number[];
  /** 1-based editor lines with a {CLR}-style magazine control token. */
  readonly braceLines: readonly number[];
  /** What a keyword-entry machine cannot type as written (keywordEntry.ts),
   *  by 1-based editor line. Printable ASCII only: the rest is in `bad`. */
  readonly keywordIssues: readonly (KeywordIssue & { readonly line: number })[];
  /** Lines the typist would send. */
  readonly lines: readonly string[];
  /** Keystrokes per typed line: characters, or chords on a keyword machine. */
  readonly keystrokes: readonly number[];
}

export function checkListing(
  text: string, config: Pick<TypeInConfig, 'maxLineChars'>, spec: DialectSpec, keywords?: KeywordMachine,
): ListingCheck {
  const bad: string[] = [];
  const badLines: number[] = [];
  const longLines: number[] = [];
  const braceLines: number[] = [];
  const keywordIssues: (KeywordIssue & { line: number })[] = [];
  cleanListing(text).split('\n').forEach((line, index) => {
    let lineBad = false;
    for (const ch of line) {
      if (isTypable(ch)) continue;
      lineBad = true;
      if (!bad.includes(ch)) bad.push(ch);
    }
    if (lineBad) badLines.push(index + 1);
    if (config.maxLineChars && [...line].length > config.maxLineChars) longLines.push(index + 1);
    if (spec.braceTokens && /\{[A-Za-z0-9 ]{1,12}\}/.test(line)) braceLines.push(index + 1);
    if (keywords && line.trim()) {
      for (const issue of transcodeLine(line, keywords).issues) {
        if ([...issue.text].every(isTypable)) keywordIssues.push({ ...issue, line: index + 1 });
      }
    }
  });
  const lines = linesToType(text);
  return {
    bad,
    foldable: bad.filter((ch) => FOLDS[ch] !== undefined).length,
    badLines,
    longLines,
    braceLines,
    keywordIssues,
    lines,
    keystrokes: lines.map((line) => (keywords ? transcodeLine(line, keywords).chords.length : line.length)),
  };
}

/** Fold the letters of BASIC CODE, leaving literals (strings, REM, DATA, `'`
 *  comments) in the visitor's case. */
function foldCode(line: string, fold: (s: string) => string, spec: DialectSpec): string {
  let out = '';
  let inString = false;
  let inData = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '"') { inString = !inString; out += ch; continue; }
    if (inString) { out += ch; continue; }
    if (inData) { if (ch === ':') inData = false; out += ch; continue; }
    if (spec.apostropheComment && ch === "'") return out + line.slice(i);
    const atWord = i === 0 || !/[A-Za-z]/.test(line[i - 1]) || spec.crunched;
    const word = line.slice(i, i + 4).toUpperCase();
    if (atWord && word.startsWith('REM')) return out + fold(line.slice(i, i + 3)) + line.slice(i + 3);
    if (atWord && word === 'DATA') { out += fold(line.slice(i, i + 4)); i += 3; inData = true; continue; }
    out += fold(ch);
  }
  return out;
}

/** Apply the station's case rule (registry `typeIn.case`) to one line. */
export function applyCase(line: string, rule: TypeInCase | undefined, spec: DialectSpec): string {
  switch (rule) {
    case 'unshifted': return line.toLowerCase();
    case 'code-upper': return foldCode(line, (s) => s.toUpperCase(), spec);
    case 'code-lower': return foldCode(line, (s) => s.toLowerCase(), spec);
    default: return line;
  }
}

/** How long typing takes at this pace, given each line's keystroke count
 *  (ListingCheck.keystrokes), for the "about 2 min" estimate. */
export function estimateMs(
  keystrokes: readonly number[],
  pace: { perCharMs: number; lineDelayMs: number; enterDelayMs: (index: number) => number },
): number {
  return keystrokes.reduce((ms, n, index) => ms + n * pace.perCharMs + pace.lineDelayMs + pace.enterDelayMs(index), 0);
}

export function formatDuration(ms: number): string {
  const s = Math.max(1, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  const rest = s % 60;
  return rest ? `${m} min ${rest} s` : `${m} min`;
}
