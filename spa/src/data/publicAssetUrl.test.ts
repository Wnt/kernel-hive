import { describe, expect, it } from 'vitest';
import { publicAssetUrl } from './publicAssetUrl';

describe('publicAssetUrl', () => {
  it('keeps production public paths and resolves staged root or relative paths', () => {
    expect(publicAssetUrl('/posters/msxturbor/desktop.webp', '/')).toBe('/posters/msxturbor/desktop.webp');
    for (const src of ['/posters/msxturbor/desktop.webp?v=2#preview', 'posters/msxturbor/desktop.webp?v=2#preview']) {
      expect(publicAssetUrl(src, '/staging/wave/')).toBe('/staging/wave/posters/msxturbor/desktop.webp?v=2#preview');
    }
  });

  it('normalizes a base without a trailing slash and does not prefix twice', () => {
    expect(publicAssetUrl('/posters/example.webp', '/staging/wave')).toBe('/staging/wave/posters/example.webp');
    expect(publicAssetUrl('/staging/wave/posters/example.webp', '/staging/wave/')).toBe('/staging/wave/posters/example.webp');
  });

  it.each(['https://example.com/photo.webp', '//example.com/photo.webp', 'data:image/png;base64,AA==', 'blob:https://example.com/id', '#image', ''])('preserves non-public URL %s', (src) => {
    expect(publicAssetUrl(src, '/staging/wave/')).toBe(src);
  });
});
