// Unit coverage for the curated-catalog enrichment adapter: runtime manifest
// fields win, curated CATALOG rows fill gaps, and the deterministic fallback
// (accent hash, era-from-year) covers ids the catalog has never heard of.
import { describe, expect, it } from 'vitest';
import { enrich } from './catalog';
import type { VMManifestEntry } from '../types';

function baseEntry(overrides: Partial<VMManifestEntry> = {}): VMManifestEntry {
  return {
    id: 'kolibrios',
    displayName: 'KolibriOS',
    year: 2004,
    lineage: 'from-scratch asm OS',
    arch: 'x86',
    archetypeId: 'beige-tower-crt',
    transport: 'streamhost',
    order: 0,
    eraLabel: '2004 · asm GUI OS',
    notes: '',
    ...overrides,
  } as VMManifestEntry;
}

describe('enrich', () => {
  it('fills accent/era/software/blurb from the curated catalog when the manifest omits them', () => {
    const result = enrich(baseEntry());
    expect(result.accent).toBe('#39c6d6');
    expect(result.periodBrowser).toBe('WebView (HTMLv)');
    expect(result.eraSoftware).toContain('KolibriOS desktop');
  });

  it('never overrides fields the manifest already sets (additive only)', () => {
    const result = enrich(baseEntry({ accent: '#ff0000', blurb: 'custom blurb' }));
    expect(result.accent).toBe('#ff0000');
    expect(result.blurb).toBe('custom blurb');
  });

  it('falls back to notes for blurb when neither the manifest nor catalog has one', () => {
    const result = enrich(baseEntry({ id: 'unknown-id', notes: 'from notes' }));
    expect(result.blurb).toBe('from notes');
  });

  it('derives a deterministic fallback accent for an id absent from the catalog', () => {
    const a = enrich(baseEntry({ id: 'some-unknown-tile' }));
    const b = enrich(baseEntry({ id: 'some-unknown-tile' }));
    expect(a.accent).toBe(b.accent);
    expect(a.accent).toMatch(/^#[0-9a-f]{6}$/);
  });

  it('derives era from the decade of the year when absent from both manifest and catalog', () => {
    const result = enrich(baseEntry({ id: 'unknown-id', year: 1987 }));
    expect(result.era).toBe('1980s');
  });

  it('returns "unknown" era for a non-numeric year with no catalog entry', () => {
    const result = enrich(baseEntry({ id: 'unknown-id', year: 'n/a' as unknown as number }));
    expect(result.era).toBe('unknown');
  });
});
