import { createElement } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it, vi } from 'vitest';
import { KeyCap } from './KeyCap';
import { NOKIA9300_DRAWING } from './nokia9300/drawing';

describe('drawn key accessibility and geometry', () => {
  const noop = () => {};
  const props = { down: false, latched: false, shortcut: '', onDown: noop, onUp: noop, onPress: noop, onRelease: noop };

  it('renders every native button at its declared, non-overlapping hit rectangle', () => {
    const boxes = NOKIA9300_DRAWING.keys.map((k) => {
      const html = renderToStaticMarkup(createElement('svg', null, createElement(KeyCap, { ...props, k })));
      const [, x, y, w, h] = html.match(/<foreignObject x="([^"]+)" y="([^"]+)" width="([^"]+)" height="([^"]+)"/)!;
      expect(html).toContain('type="button"');
      expect(html).toContain('aria-label=');
      expect([+x, +y, +w, +h]).toEqual([k.box.x, k.box.y, k.box.w, k.box.h]);
      return { id: k.id, x: +x, y: +y, w: +w, h: +h };
    });
    for (let i = 0; i < boxes.length; i++) {
      for (const b of boxes.slice(i + 1)) {
        const a = boxes[i];
        expect(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h,
          `${a.id} overlaps ${b.id}`).toBe(false);
      }
    }
    const s = NOKIA9300_DRAWING.screen;
    expect(Math.abs(s.w / s.h - 3.2)).toBeLessThanOrEqual(0.01);
  });

  it.each(['Enter', ' '])('pairs %j down/up, ignores repeat, and releases on focus loss', async (key) => {
    const onPress = vi.fn(), onRelease = vi.fn();
    let root: ReactTestRenderer;
    await act(() => {
      root = create(createElement(KeyCap, { ...props, k: NOKIA9300_DRAWING.keys[0], onPress, onRelease }));
    });
    const input = root!.root.findByType('input');
    const event = { key, repeat: false, preventDefault: vi.fn(), stopPropagation: vi.fn() };
    input.props.onKeyDown(event);
    input.props.onKeyDown({ ...event, repeat: true });
    expect(onPress).toHaveBeenCalledTimes(1);
    input.props.onKeyUp(event);
    expect(onRelease).toHaveBeenCalledTimes(1);
    input.props.onKeyDown(event);
    input.props.onBlur();
    expect(onRelease).toHaveBeenCalledTimes(2);
    expect(event.preventDefault).toHaveBeenCalled();
    await act(() => root!.unmount());
  });
});
