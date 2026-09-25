import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import sharp from 'sharp';
import { describe, expect, it } from 'vitest';
import { Nokia9300Outline } from './Outline';
import { NokiaWordmark } from './Wordmark';
import { SCREEN, VIEW_H, VIEW_W } from './keys';

describe('Nokia ink on the display bezel', () => {
  const markup = renderToStaticMarkup(createElement(NokiaWordmark));

  it('renders five original path letterforms in the device ink, without font geometry', () => {
    expect(markup.match(/<path /g)).toHaveLength(5);
    expect(markup).toContain('fill="var(--dev-ink)"');
    expect(markup).toContain('stroke="none"');
    expect(markup).not.toMatch(/<text|<image|<use|font/);
    expect(renderToStaticMarkup(createElement(Nokia9300Outline))).toContain(markup);
  });

  it('paints centred on the display, a cap-height below its bezel and clear of the hinge', async () => {
    // Measure painted pixels, so changing a path without its placement cannot
    // silently escape a test that only checks declared dimensions.
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${VIEW_W}" height="${VIEW_H}">${markup}</svg>`;
    const { data, info } = await sharp(new TextEncoder().encode(svg)).ensureAlpha().raw()
      .toBuffer({ resolveWithObject: true });
    let left = VIEW_W, top = VIEW_H, right = 0, bottom = 0;
    for (let y = 0; y < info.height; y++) {
      for (let x = 0; x < info.width; x++) {
        if (data[(y * info.width + x) * 4 + 3] === 0) continue;
        left = Math.min(left, x); right = Math.max(right, x + 1);
        top = Math.min(top, y); bottom = Math.max(bottom, y + 1);
      }
    }
    expect((left + right) / 2).toBe(SCREEN.x + SCREEN.w / 2);
    expect(right - left).toBe(114);
    expect(bottom - top).toBeLessThanOrEqual(19); // 18 units plus half-pixel edges
    const bezelBottom = SCREEN.y + SCREEN.h + 9 + 3.5 / 2;
    expect(top - bezelBottom).toBeGreaterThanOrEqual(17.5);
    expect(top - bezelBottom).toBeLessThanOrEqual(18.5);
    expect(500 - 3.5 / 2 - bottom).toBeGreaterThanOrEqual(7);
    expect(left).toBeGreaterThan(SCREEN.x);
    expect(right).toBeLessThan(SCREEN.x + SCREEN.w);
  });
});
