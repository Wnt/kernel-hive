import type { DialectSpec } from './basicDialects';

// ---------------------------------------------------------------------------
//  basicHighlight — paint one listing line: line number, keywords, strings,
//  numbers, REM / comments, and the characters the typist CANNOT key.
//
//  Deliberately small and line-local (a BASIC statement never spans lines),
//  so the editor re-highlights only what React re-renders. Everything that is
//  not printable ASCII comes out as its own `bad` token whatever context it
//  sits in — a curly quote inside a string is exactly the character a visitor
//  pastes from a web page and the machine never receives.
// ---------------------------------------------------------------------------

type TokenKind =
  | 'lineno' | 'keyword' | 'string' | 'number' | 'comment' | 'ident' | 'op' | 'space' | 'bad' | 'ctrl';

export interface Token {
  readonly kind: TokenKind;
  readonly text: string;
  /** Past the machine's line limit (typeIn.maxLineChars): the screen editor drops it. */
  readonly over?: boolean;
}

const PRINTABLE = /^[\x20-\x7e]$/;
const LETTER = /[A-Za-z]/;
const WORD_CHAR = /[A-Za-z0-9]/;
const NUMBER = /^(\d+\.?\d*|\.\d+)(E[+-]?\d+)?/i;
const HEX = /^&([Hh][0-9A-Fa-f]+|[Bb][01]+|[Oo][0-7]+|[0-9A-Fa-f]+)/;
// A magazine listing's control key, written out in braces: {CLR}, {DOWN}, {RVS ON}.
const BRACE = /^\{[A-Za-z0-9 ]{1,12}\}/;

export function isTypable(ch: string): boolean {
  return PRINTABLE.test(ch);
}

class Line {
  readonly tokens: Token[] = [];

  /** `blocked`: printable ASCII this station's keymap cannot produce. */
  constructor(private readonly blocked = '') {}

  push(kind: TokenKind, text: string): void {
    if (!text) return;
    let run = '';
    for (const ch of text) {
      if (isTypable(ch) && !this.blocked.includes(ch)) { run += ch; continue; }
      this.add(kind, run);
      run = '';
      this.add('bad', ch);
    }
    this.add(kind, run);
  }

  private add(kind: TokenKind, text: string): void {
    if (!text) return;
    const last = this.tokens[this.tokens.length - 1];
    // Adjacent same-kind runs merge (two identifier halves around a `$`) —
    // but never `bad`: each one is a character the visitor has to find.
    if (last && last.kind === kind && kind !== 'bad') this.tokens[this.tokens.length - 1] = { kind, text: last.text + text };
    else this.tokens.push({ kind, text });
  }
}

/** A string literal from its opening quote: up to the closing quote or end of line. */
function readString(line: string, at: number, spec: DialectSpec, out: Line): number {
  const close = line.indexOf('"', at + 1);
  const end = close === -1 ? line.length : close + 1;
  let i = at;
  let start = at;
  while (i < end) {
    const brace = spec.braceTokens && line[i] === '{' ? BRACE.exec(line.slice(i, end)) : null;
    if (brace) {
      out.push('string', line.slice(start, i));
      out.push('ctrl', brace[0]);
      i += brace[0].length;
      start = i;
    } else i += 1;
  }
  out.push('string', line.slice(start, end));
  return end;
}

/** One run of letters/digits/$/%: keywords per the dialect's matching rule. */
function readWord(line: string, at: number, spec: DialectSpec, out: Line): { end: number; rem: boolean } {
  let end = at;
  while (end < line.length && WORD_CHAR.test(line[end])) end += 1;
  if (end < line.length && (line[end] === '$' || line[end] === '%')) end += 1;
  const word = line.slice(at, end);
  if (!spec.crunched) {
    const upper = word.toUpperCase();
    const kind = spec.keywords.has(upper) ? 'keyword' : 'ident';
    out.push(kind, word);
    return { end, rem: upper === 'REM' };
  }
  // Crunched: keywords are found anywhere in the run, longest first, exactly
  // as the machine's own tokeniser reads `FORI=1TO10`.
  let i = at;
  let afterKeyword = false;
  while (i < end) {
    const rest = line.slice(i, end).toUpperCase();
    // Digits straight after a keyword are a number (`TO10`), not the tail of
    // a variable name (`A1`).
    const number = afterKeyword ? /^\d+/.exec(rest) : null;
    const hit = number ? undefined : spec.byLength.find((k) => rest.startsWith(k));
    if (number) {
      out.push('number', number[0]);
      i += number[0].length;
      afterKeyword = false;
    } else if (hit) {
      out.push('keyword', line.slice(i, i + hit.length));
      i += hit.length;
      afterKeyword = true;
      if (hit === 'REM') return { end: i, rem: true };
    } else {
      out.push('ident', line[i]);
      i += 1;
      afterKeyword = false;
    }
  }
  return { end, rem: false };
}

/** Tokens for one line of a listing, in order, covering every character.
 *  `blocked` symbols (registry `typeIn.unreachable`) paint as `bad`. */
export function highlightLine(line: string, spec: DialectSpec, blocked?: string): Token[] {
  const out = new Line(blocked);
  const lead = /^(\s*)(\d+)/.exec(line);
  let i = 0;
  if (lead) {
    out.push('space', lead[1]);
    out.push('lineno', lead[2]);
    i = lead[0].length;
  }
  while (i < line.length) {
    const ch = line[i];
    const rest = line.slice(i);
    if (ch === '"') { i = readString(line, i, spec, out); continue; }
    if (spec.apostropheComment && ch === "'") { out.push('comment', rest); break; }
    if (LETTER.test(ch)) {
      const word = readWord(line, i, spec, out);
      i = word.end;
      if (word.rem) { out.push('comment', line.slice(i)); break; }
      continue;
    }
    const number = /[0-9.]/.test(ch) ? NUMBER.exec(rest) : ch === '&' ? HEX.exec(rest) : null;
    if (number) { out.push('number', number[0]); i += number[0].length; continue; }
    const brace = spec.braceTokens && ch === '{' ? BRACE.exec(rest) : null;
    if (brace) { out.push('ctrl', brace[0]); i += brace[0].length; continue; }
    // One CODE POINT, not one UTF-16 unit: an emoji split into two lone
    // surrogates would paint two glyphs over the textarea's one and shift
    // every character after it out from under the caret.
    const point = String.fromCodePoint(line.codePointAt(i) ?? 0);
    if (spec.questionPrint && point === '?') out.push('keyword', point);
    else out.push(point === ' ' ? 'space' : 'op', point);
    i += point.length;
  }
  return out.tokens;
}

/** Split `tokens` at character `max`, marking everything after it `over`. */
export function markOverflow(tokens: readonly Token[], max: number | undefined): Token[] {
  if (!max) return [...tokens];
  const out: Token[] = [];
  let seen = 0;
  for (const token of tokens) {
    const len = [...token.text].length;
    if (seen >= max) out.push({ ...token, over: true });
    else if (seen + len <= max) out.push(token);
    else {
      const chars = [...token.text];
      out.push({ kind: token.kind, text: chars.slice(0, max - seen).join('') });
      out.push({ kind: token.kind, text: chars.slice(max - seen).join(''), over: true });
    }
    seen += len;
  }
  return out;
}

/** Repaint the character ranges a keyword-entry machine cannot type as `bad`
 *  (keywordEntry.ts issues: `at` is a column, `len` how many characters). */
export function markBad(tokens: readonly Token[], ranges: readonly { at: number; len: number }[]): Token[] {
  if (!ranges.length) return [...tokens];
  const inRange = (col: number) => ranges.some((r) => col >= r.at && col < r.at + r.len);
  const out: Token[] = [];
  let col = 0;
  for (const token of tokens) {
    let run = '';
    let runBad = false;
    for (const ch of token.text) {
      const isBad = inRange(col);
      if (run && isBad !== runBad) {
        out.push({ ...token, kind: runBad ? 'bad' : token.kind, text: run });
        run = '';
      }
      run += ch;
      runBad = isBad;
      col += ch.length;
    }
    if (run) out.push({ ...token, kind: runBad ? 'bad' : token.kind, text: run });
  }
  return out;
}
