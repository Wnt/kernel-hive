// Pure derivation of the status pill + debug readout strings — extracted
// verbatim from the StreamView orchestrator (mechanical cap-relief move; the
// logic is unchanged). No React, no DOM.

import type { StreamStats } from '../../../three/useStreamControl';

export function deriveStatus(a: {
  transport: string;
  streamable: boolean;
  phase: string;
  mediaLive: boolean;
  connected: boolean;
  nativeWebRtcFallback: boolean;
  displayName: string;
  live: boolean;
  message: string;
  stats: StreamStats | null;
  resolution: { w: number; h: number } | null;
}): { dotColor: string; statusLabel: string; bufReadout: string; resStr: string; codecStr: string } {
  const isShowcase = a.transport === 'showcase';

  // Status ink, not status glow: these sit on the light stage menu, so each is
  // the museum-daylight semantic colour at a weight that reads on paper.
  const dotColor = isShowcase
    ? '#6f6857' // neutral — a showcase poster is neither connecting nor live
    : a.streamable && a.phase === 'error'
      ? '#b23a2c'
      : a.mediaLive && (a.connected || a.nativeWebRtcFallback)
        ? '#1d7a4c'
        : '#8f6407';

  // A HEALTHY session says only the machine's name. The old "— CONTROL · host"
  // suffix reported the normal case, which is exactly the case that needs no
  // words; the remaining suffixes all mark something the visitor would
  // otherwise have to guess (a poster, a degraded transport, input not yet
  // attached, an outright failure).
  const statusLabel = isShowcase
    ? `${a.displayName} — SHOWCASE`
    : a.live
      ? a.nativeWebRtcFallback
        ? `${a.displayName} — LIVE · WebRTC fallback`
        : a.connected
        ? a.displayName
        : `${a.displayName} — LIVE (connecting input…)`
      : a.phase === 'error'
        ? a.message || 'stream unavailable'
        : a.message || `Connecting to ${a.displayName}…`;

  const bufReadout =
    a.stats && a.stats.jitterTargetMs != null
      ? `${a.stats.jitterBufferMs ?? '–'}/${a.stats.jitterTargetMs}ms${a.stats.jitterAuto ? ' auto' : ''}`
      : `${a.stats?.jitterBufferMs ?? '–'} ms`;

  const resStr = a.streamable
    ? `${a.stats?.frameWidth ?? a.resolution?.w ?? '–'}×${a.stats?.frameHeight ?? a.resolution?.h ?? '–'}`
    : '–';

  return { dotColor, statusLabel, bufReadout, resStr, codecStr: '–' };
}
