import type { OSBinding } from './archetypeRegistry';
import {
  useStreamhostSession,
  type StreamSessionOptions,
  type StreamSessionResult,
} from './useStreamhostSession';
import { streamhostSignalFor } from './streamSignal';

// ============================================================================
//  useLiveStream — shared hook for the grid's live streamhost transport
//  ---------------------------------------------------------------------------
//  Opens a tile's media/control session. Showcase bindings remain inactive.
// ============================================================================

export function useLiveStream(
  binding: OSBinding | undefined,
  active: boolean,
  options?: StreamSessionOptions,
): StreamSessionResult {
  const wantStream = binding?.transport === 'streamhost';
  const signal = binding ? streamhostSignalFor(binding) : '';
  return useStreamhostSession(signal, active && wantStream, {
    ...options,
    osId: binding?.osId,
  });
}
