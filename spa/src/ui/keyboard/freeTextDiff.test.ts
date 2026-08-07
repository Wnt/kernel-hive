// Sentinel + value-diff semantics for the mobile sheet's free-text proxy input.
import { describe, expect, it } from 'vitest';
import { diffProxyValue } from './freeTextDiff';
import { PROXY_SENTINEL } from './oskConstants';

describe('diffProxyValue', () => {
  it('a lone sentinel is a noop (idempotent after reset)', () => {
    expect(diffProxyValue(PROXY_SENTINEL)).toEqual({ backspaces: 0, text: '' });
  });

  it('sentinel + typed text yields the text', () => {
    expect(diffProxyValue(`${PROXY_SENTINEL}abc`)).toEqual({ backspaces: 0, text: 'abc' });
  });

  it('a deleted sentinel is exactly one Backspace', () => {
    expect(diffProxyValue('')).toEqual({ backspaces: 1, text: '' });
  });

  it('sentinel gone + char present = one Backspace then the char', () => {
    expect(diffProxyValue('x')).toEqual({ backspaces: 1, text: 'x' });
  });

  it('a multi-char IME commit arrives whole (composed word + space)', () => {
    expect(diffProxyValue(`${PROXY_SENTINEL}hello `)).toEqual({ backspaces: 0, text: 'hello ' });
  });

  it('stray sentinels inside the value are stripped from the sent text', () => {
    expect(diffProxyValue(`${PROXY_SENTINEL}a${PROXY_SENTINEL}b`)).toEqual({ backspaces: 0, text: 'ab' });
  });
});
