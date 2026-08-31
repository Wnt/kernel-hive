// The public TYPE surface of useStreamhostSession, lifted out of the hook.
// Nothing here is behaviour — it moved because the hook file sits ON the
// repo's 600-line hard cap (scripts/check-file-size.mjs), and a declaration
// block is the part of a god-file that costs nothing to read somewhere else.
// The hook re-exports all three, so no importer changes.

import type { VideoSinkProbe } from './streamClient/videoResume';
import type { StreamControlHandle } from './useStreamControl';



export type LivePhase = 'idle' | 'starting' | 'connecting' | 'live' | 'error';

export interface StreamSessionOptions {
  /** Construct and expose the imperative input/control handle. */
  control?: boolean;
  /** HUD-compatible target value; streamhost itself has no receiver jitter buffer. */
  jitterBufferTargetMs?: number;
  /** Keep the HUD's automatic/manual latency-control state. */
  autoJitter?: boolean;
  /** OS id, selects the guest-quirks profile in the controller. */
  osId?: string;
  /**
   * Read the visible <video>'s state. The session hook does not own that
   * element, but it cannot tell "nothing is arriving" from "nothing is being
   * consumed" without it — and those two want opposite responses.
   */
  sinkProbe?: () => VideoSinkProbe | null;
}

export interface StreamSessionResult {
  phase: LivePhase;
  message: string;
  control: StreamControlHandle | null;
  stream: MediaStream | null;
  registerPaintCanvas?: (el: HTMLCanvasElement | null) => void;
  beginRestoreReconnect?: () => void;
  finishRestoreReconnect?: () => void;
  expectedReconnect: 'restore' | null;
  /** Abandon the current attempt and start a fresh ladder (visitor gesture). */
  reconnectNow: () => void;
  /**
   * A TRUSTED human input edge was directed at this guest.
   *
   * The session hook cannot witness this itself — the events land on the view's
   * own elements, which it does not own, exactly like `sinkProbe` above. Only
   * the FIRST edge changes anything (`station.open.toFirstInputMs`), so this is
   * cheap to over-call and must never be called for SYNTHETIC input: a type-in
   * demo puts hundreds of edges on the wire from one click, and crediting those
   * would report every scripted station as instantly discoverable.
   */
  noteInput: () => void;
}
