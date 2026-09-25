import { createElement } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { DeviceStage } from './DeviceStage';
import { NOKIA9300_DRAWING } from './nokia9300/drawing';

afterEach(() => vi.unstubAllGlobals());

describe('device drawing presentation', () => {
  it('has no caption while retaining the device name and accessible key shortcuts', async () => {
    const events = { addEventListener: vi.fn(), removeEventListener: vi.fn() };
    vi.stubGlobal('window', events);
    vi.stubGlobal('document', { ...events, hidden: false });
    let view: ReactTestRenderer;
    await act(() => {
      view = create(createElement(DeviceStage, {
        drawing: NOKIA9300_DRAWING, handle: null, children: null,
      }));
    });
    try {
      expect(view!.root.findAllByType('p')).toHaveLength(0);
      expect(JSON.stringify(view!.toJSON())).not.toContain('Press the drawn keys');
      expect(view!.root.findByProps({ role: 'group' }).props['aria-label'])
        .toBe(NOKIA9300_DRAWING.name);
      const inputs = view!.root.findAllByType('input');
      expect(inputs).toHaveLength(NOKIA9300_DRAWING.keys.length);
      expect(inputs.every((input) => input.props['aria-label'])).toBe(true);
      expect(view!.root.findAllByType('title').some((title) =>
        title.children.join('').includes('F1'))).toBe(true);
    } finally {
      await act(() => view!.unmount());
    }
  });
});
