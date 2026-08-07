import { describe, expect, it } from 'vitest';
import { streamhostSignalFor } from './streamSignal';
import type { OSBinding } from './archetypeRegistry';

// Minimal OSBinding stub — only the two fields streamhostSignalFor reads.
function binding(osId: string, signalEndpoint?: string): OSBinding {
  return { osId, signalEndpoint } as unknown as OSBinding;
}

describe('streamhostSignalFor', () => {
  it('returns the explicit signalEndpoint when the binding sets one', () => {
    expect(streamhostSignalFor(binding('win95', '/custom/win95.json'))).toBe('/custom/win95.json');
  });

  it('derives the same-origin /signal/<osId>.json path when unset', () => {
    expect(streamhostSignalFor(binding('c64'))).toBe('/signal/c64.json');
  });

  it('falls back to the derived path for an empty-string endpoint too', () => {
    expect(streamhostSignalFor(binding('haiku', ''))).toBe('/signal/haiku.json');
  });
});
