// Tests for the page binding. What matters is that the binding is EXPLICIT
// (present on the event, not inferred) and LOW-CARDINALITY (a route pattern,
// never 63 station paths).

import { describe, expect, it, afterEach, beforeEach } from 'vitest';
import {
  pageBindingAttrs, pageLoadId, pagePattern, __resetPageBinding,
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

describe('pageBindingAttrs', () => {
  it('carries exactly the pattern and this document\'s load id', () => {
    setWindow({ location: { pathname: '/os/beos' } });
    expect(pageBindingAttrs()).toEqual({
      'kh.page.pattern': '/os/:osId',
      'kh.page.loadId': pageLoadId(),
    });
  });
});
