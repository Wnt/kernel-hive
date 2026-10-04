import { describe, expect, it } from 'vitest';
import { DIALECTS, dialectSpec } from './basicDialects';
import { highlightLine, markOverflow, type Token } from './basicHighlight';
import { typeInFor } from '../../data/demoPrograms';

const cbm = dialectSpec('cbm-basic');
const msx = dialectSpec('msx-basic');
const ql = dialectSpec('superbasic');

const kinds = (tokens: Token[]) => tokens.map((t) => [t.kind, t.text]);
const of = (tokens: Token[], kind: Token['kind']) => tokens.filter((t) => t.kind === kind).map((t) => t.text);

describe('highlightLine', () => {
  it('covers every character of the line, in order', () => {
    for (const line of ['10 PRINT "HI";A$:GOTO 10', '  20 fori=1to10:next', '30 REM “smart” stuff', '', '?']) {
      expect(highlightLine(line, cbm).map((t) => t.text).join('')).toBe(line);
    }
  });

  it('paints the line number, keywords, strings and numbers', () => {
    const tokens = highlightLine('10 PRINT "HELLO";3.5E2', cbm);
    expect(kinds(tokens)).toEqual([
      ['lineno', '10'], ['space', ' '], ['keyword', 'PRINT'], ['space', ' '],
      ['string', '"HELLO"'], ['op', ';'], ['number', '3.5E2'],
    ]);
  });

  it('finds keywords inside unspaced code on a crunching BASIC, case-insensitively', () => {
    // The machine reads FORI=1TO10 as FOR I = 1 TO 10, so the editor does too.
    const tokens = highlightLine('20 fori=1to10:next', cbm);
    expect(of(tokens, 'keyword')).toEqual(['for', 'to', 'next']);
    expect(of(tokens, 'ident')).toEqual(['i']);
  });

  it('matches whole words only on a BASIC that needs spaces', () => {
    const tokens = highlightLine('60 DEFine PROCedure rose(n,c)', ql);
    expect(of(tokens, 'keyword')).toEqual(['DEFine', 'PROCedure']);
    expect(of(tokens, 'ident')).toContain('rose');
  });

  it('turns the rest of the line into a comment after REM', () => {
    const tokens = highlightLine('30 REM PRINT "NOT CODE"', cbm);
    expect(kinds(tokens).slice(-1)).toEqual([['comment', ' PRINT "NOT CODE"']]);
  });

  it("treats ' as a comment only where the dialect does", () => {
    expect(of(highlightLine("40 CLS ' clear", msx), 'comment')).toEqual(["' clear"]);
    expect(of(highlightLine("40 PRINT 'X", cbm), 'comment')).toEqual([]);
  });

  it('flags every character the typist cannot key, even inside a string', () => {
    const tokens = highlightLine('10 PRINT “HI”', cbm);
    expect(of(tokens, 'bad')).toEqual(['“', '”']);
  });

  it('keeps an emoji as ONE bad token so the overlay stays aligned', () => {
    expect(of(highlightLine('10 X=1 🙂', cbm), 'bad')).toEqual(['🙂']);
  });

  it('marks magazine control codes on Commodore listings only', () => {
    expect(of(highlightLine('10 PRINT "{CLR}HI"', cbm), 'ctrl')).toEqual(['{CLR}']);
    expect(of(highlightLine('10 PRINT "{CLR}HI"', msx), 'ctrl')).toEqual([]);
  });

  it('reads hex literals', () => {
    expect(of(highlightLine('10 A=&HFF', msx), 'number')).toEqual(['&HFF']);
  });
});

describe('markOverflow', () => {
  it('splits a token at the machine line limit and marks the rest', () => {
    const tokens = markOverflow(highlightLine('10 PRINT "ABCDEFGH"', cbm), 12);
    expect(tokens.map((t) => t.text).join('')).toBe('10 PRINT "ABCDEFGH"');
    expect(tokens.filter((t) => t.over).map((t) => t.text).join('')).toBe('CDEFGH"');
  });

  it('changes nothing without a limit', () => {
    const tokens = highlightLine('10 PRINT', cbm);
    expect(markOverflow(tokens, undefined)).toEqual(tokens);
  });
});

describe('dialects', () => {
  it('has a keyword list for every dialect a registry station declares', () => {
    for (const id of ['vic20', 'bbcmicro', 'msx2', 'amstradcpc', 'sinclairql', 'samcoupe', 'oricatmos', 'dragon32', 'mpf2']) {
      const config = typeInFor(id);
      expect(config, id).toBeDefined();
      expect(DIALECTS).toContain(config!.dialect);
      expect(dialectSpec(config!.dialect).keywords.has('PRINT')).toBe(true);
    }
  });
});
