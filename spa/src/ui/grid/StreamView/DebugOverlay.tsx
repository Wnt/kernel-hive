import type { StreamStats } from '../../../three/useStreamControl';
import { S } from './styles';

function DebugRow({ k, v }: { k: string; v: string }) {
  return (
    <div style={S.debugRow}>
      <span style={S.debugKey}>{k}</span>
      <span style={S.debugVal}>{v}</span>
    </div>
  );
}

// DEBUG OVERLAY — hidden by default; Cmd/Ctrl+N toggles. Overlays the picture in
// BOTH windowed + fullscreen so it never pollutes the frame. The parent gates
// mounting on `debug && streamable`.
export function DebugOverlay({
  displayName, transport, shRows, stats, bufReadout, resStr, codecStr,
}: {
  displayName: string;
  transport: string;
  shRows: Array<{ k: string; v: string }> | null;
  stats: StreamStats | null;
  bufReadout: string;
  resStr: string;
  codecStr: string;
}) {
  return (
    <div style={S.debug}>
      <div style={S.debugTitle}>{displayName} · {transport}</div>
      {shRows ? (
        // STREAMHOST: the full codec/ABR readout (Section 4 rows 1–12).
        <>
          {shRows.map((r) => <DebugRow key={r.k} k={r.k} v={r.v} />)}
        </>
      ) : (
        // Native fallback / pre-metrics: compact readout.
        <>
          <DebugRow k="fps" v={`${stats?.fps ?? '–'}`} />
          <DebugRow k="rtt" v={`${stats?.rttMs ?? '–'} ms`} />
          <DebugRow k="jitter buf" v={bufReadout} />
          <DebugRow k="resolution" v={resStr} />
          <DebugRow k="codec" v={codecStr} />
        </>
      )}
      <div style={S.debugHint}>⌘/Ctrl+N toggles</div>
    </div>
  );
}
