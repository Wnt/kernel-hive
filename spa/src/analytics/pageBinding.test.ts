// Tests for the page binding — the capability Instana's browser agent does not
// have. What matters is that the binding is EXPLICIT (present on the event,
// not inferred), LOW-CARDINALITY (a route pattern, never 63 station paths) and
// SURVIVES the vendor being absent, which is the state we are building for.

import { describe, expect, it, afterEach, beforeEach } from 'vitest';
import {
  instanaPageLoadId, pageBindingAttrs, pageLoadId, pagePattern, __resetPageBinding,
} from './pageBinding';

function setWindow(w: unknown): void {
  (globalThis as { window?: unknown }).window = w;
}

beforeEach(() => __resetPageBinding());
afterEach(() => { delete (globalThis as { window?: unknown }).window; __resetPageBinding(); });

describe('pageLoadId', () => {
  it('is 16 hex characters and stable for the life of the document', () => {
    const a = pageLoadId();
    expect(a).toMatch(/^[0-9a-f]{16}$/);
    expect(pageLoadId()).toBe(a);
  });

  it('is a NEW id after a reset — a new document is a new page load', () => {
    const a = pageLoadId();
    __resetPageBinding();
    expect(pageLoadId()).not.toBe(a);
  });
});

describe('pagePattern', () => {
  it('is the route PATTERN, so 63 stations group as one page', () => {
    setWindow({ location: { pathname: '/os/beos' } });
    expect(pagePattern()).toBe('/os/:osId');
    setWindow({ location: { pathname: '/os/irix' } });
    expect(pagePattern()).toBe('/os/:osId');
  });

  it('buckets an unmatched path instead of leaking it as a pattern', () => {
    setWindow({ location: { pathname: '/some/unknown/thing' } });
    expect(pagePattern()).toBe('*');
  });

  it('answers outside a browser rather than throwing', () => {
    expect(pagePattern()).toBe('*');
  });
});

describe('instanaPageLoadId', () => {
  it('is null on an unconfigured build — our own binding does not depend on it', () => {
    setWindow({ location: { pathname: '/' } });
    expect(instanaPageLoadId()).toBeNull();
    const attrs = pageBindingAttrs();
    expect(attrs['kh.page.loadId']).toBeDefined();
    expect(attrs['kh.page.instanaLoadId']).toBeUndefined();
  });

  it('captures the vendor id when it is there, for reconciliation while it lasts', () => {
    setWindow({
      location: { pathname: '/fleet' },
      ineum: (verb: string) => (verb === 'getPageLoadId' ? 'abc-123' : undefined),
    });
    expect(instanaPageLoadId()).toBe('abc-123');
    expect(pageBindingAttrs()['kh.page.instanaLoadId']).toBe('abc-123');
  });

  it('ignores a non-string answer and a vendor that throws', () => {
    setWindow({ location: { pathname: '/' }, ineum: () => 42 });
    expect(instanaPageLoadId()).toBeNull();
    setWindow({ location: { pathname: '/' }, ineum: () => { throw new Error('boom'); } });
    expect(instanaPageLoadId()).toBeNull();
    expect(() => pageBindingAttrs()).not.toThrow();
  });
});
