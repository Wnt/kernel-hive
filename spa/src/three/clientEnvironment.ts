// ============================================================================
//  three/clientEnvironment — the one-line environment probe on every
//  `session-start` / `station-open` telemetry row (clientDebug.ts).
//  ---------------------------------------------------------------------------
//  The facts that explain an early failure before any transport exists:
//  missing WebTransport/WebCodecs, an insecure context, a restricted network's
//  blocked QUIC — and, since 2026-09-08, the session's ROLE, so a walk-in tab
//  reads as a stranger's in `clientcmd.sh sessions` now that the plane is open
//  to that role on purpose (docs/lab/clientcmd-admin-security.md). Kept well
//  under the 512-char detail cap and free of anything identifying beyond the
//  UA the sink already logs.
// ============================================================================
import { BUILD_ID } from '../analytics/build';
import { selectClientTransport } from './streamTransportSelect';

/** The role app boot reported (`main.tsx`), carried on every row after. */
let bootRole: string | null = null;

export function setBootRole(role: string | null | undefined): void {
  if (role) bootRole = role;
}

export function describeEnvironment(tile: string | null): string {
  const probe: Record<string, unknown> = { tile: tile ?? '', bundle: BUILD_ID };
  if (bootRole) probe.role = bootRole;
  try {
    probe.wt = typeof WebTransport !== 'undefined';
    probe.vd = typeof VideoDecoder !== 'undefined';
    probe.rtc = typeof RTCPeerConnection !== 'undefined';
    // Which client path the two facts above select (streamTransportSelect.ts),
    // so a row says `transport` outright instead of leaving it to be derived.
    probe.transport = selectClientTransport();
    probe.secure = typeof isSecureContext !== 'undefined' ? isSecureContext : null;
    probe.sw = typeof navigator !== 'undefined' && 'serviceWorker' in navigator
      ? (navigator.serviceWorker.controller ? 'controlled' : 'registered-or-none')
      : 'unsupported';
    const conn = (navigator as Navigator & {
      connection?: { effectiveType?: string; downlink?: number; rtt?: number };
    }).connection;
    if (conn) probe.net = { t: conn.effectiveType, dl: conn.downlink, rtt: conn.rtt };
    probe.hidden = typeof document !== 'undefined' ? document.visibilityState : null;
    probe.href = typeof location !== 'undefined' ? location.pathname : '';
  } catch { /* a probe must never be why telemetry is missing */ }
  try { return JSON.stringify(probe); } catch { return `tile=${tile ?? ''}`; }
}
