import type { StreamExitReason } from '../../../three/streamClient';

// ---------------------------------------------------------------------------
//  StructuredExitReason (Item 3) — map the streamClient discriminator to a
//  one-line, human disconnect copy shown in the poster/banner. Kept here (UI
//  layer) so streamClient stays copy-free.
// ---------------------------------------------------------------------------
export function exitReasonCopy(reason: StreamExitReason | null | undefined): string | null {
  switch (reason) {
    case 'user-exit': return 'Session closed by you';
    case 'transport-down': return 'Session ended — connection lost';
    case 'ping-timeout': return 'Session ended — the tile stopped responding';
    case 'stream-stalled': return 'Session ended — the video stream stalled';
    case 'device-sleep': return 'Session paused — this device went to sleep';
    case 'server-finished': return 'Session ended — the exhibit closed the stream';
    default: return null;
  }
}
