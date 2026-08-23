import { describe, expect, it } from 'vitest';
import { linkedStations, parseMarkup, plainText, stationPath } from './releaseNotesMarkup';

describe('parseMarkup', () => {
  it('leaves prose with no markers as a single text token', () => {
    expect(parseMarkup('Just words.')).toEqual([{ kind: 'text', text: 'Just words.' }]);
  });

  it('reads a station link as its own token, keeping id and label apart', () => {
    expect(parseMarkup('Try [Windows 3.11](station:win311) today')).toEqual([
      { kind: 'text', text: 'Try ' },
      { kind: 'station', text: 'Windows 3.11', id: 'win311' },
      { kind: 'text', text: ' today' },
    ]);
  });

  // The bold/italic ordering trap: `**` scanned after `*` reads every bold
  // opener as an empty italic, which silently mangles half the prose.
  it('prefers bold over italic on a doubled marker', () => {
    expect(parseMarkup('**ICQ**')).toEqual([{ kind: 'bold', children: [{ kind: 'text', text: 'ICQ' }] }]);
    expect(parseMarkup('*1991*')).toEqual([{ kind: 'italic', children: [{ kind: 'text', text: '1991' }] }]);
  });

  it('nests a station link inside the week underline', () => {
    const tokens = parseMarkup('<u>a private net on [BeOS](station:beos)</u>');
    expect(tokens).toHaveLength(1);
    expect(tokens[0].kind).toBe('underline');
    expect(linkedStations(tokens)).toEqual(['beos']);
  });

  it('does not let two underlines on one line swallow the text between', () => {
    const tokens = parseMarkup('<u>one</u> and <u>two</u>');
    expect(tokens.map((t) => t.kind)).toEqual(['underline', 'text', 'underline']);
    expect(plainText(tokens)).toBe('one and two');
  });

  // Anything outside the vocabulary must survive as literal text: the whole
  // point of tokenising is that an unknown construct renders ugly, never runs.
  it('renders an unknown tag as text rather than markup', () => {
    expect(plainText(parseMarkup('<script>alert(1)</script>'))).toBe('<script>alert(1)</script>');
    expect(parseMarkup('<b>hi</b>').every((t) => t.kind === 'text')).toBe(true);
  });

  it('leaves an unclosed marker as literal text', () => {
    expect(plainText(parseMarkup('**unclosed and on it goes'))).toBe('**unclosed and on it goes');
  });

  // parseMarkup recurses, and the module-level /g regex is stateful — a nested
  // call that did not reset lastIndex would resume mid-string in its parent.
  it('parses repeated markup on one line without losing a token', () => {
    const tokens = parseMarkup('**a** then **b** then [c](station:c64)');
    expect(tokens.map((t) => t.kind)).toEqual(['bold', 'text', 'bold', 'text', 'station']);
  });

  it('collects linked stations in first-appearance order, without repeats', () => {
    const tokens = parseMarkup('[a](station:beos) [b](station:tru64) [c](station:beos)');
    expect(linkedStations(tokens)).toEqual(['beos', 'tru64']);
  });

  // Relative on purpose: an absolute URL would bounce a reviewer out of a
  // staged UI at /staging/<session>/ and into production.
  it('builds a relative station path', () => {
    expect(stationPath('win311')).toBe('/os/win311');
  });
});
