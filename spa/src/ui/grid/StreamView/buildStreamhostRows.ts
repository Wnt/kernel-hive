import type { StreamStats } from '../../../three/useStreamControl';
import { codecStringFor, profileName, levelName, presetName } from '../../../three/streamClient';

// ---------------------------------------------------------------------------
//  STREAMHOST codec / ABR overlay rows (Section 4). Pure string building from
//  the client metric snapshot (m) + the polled StreamStats (RTT). Each source is
//  tagged in the spec: P1=KIND3/1, P2=KIND3/2, L=client-local, SIG=signaling,
//  PING=type-9. Everything is guarded so partial data still renders a clean row.
// ---------------------------------------------------------------------------
export function buildStreamhostRows(
  m: NonNullable<StreamStats['streamhost']>,
  stats: StreamStats | null,
): Array<{ k: string; v: string }> {
  const dash = '–';
  const enc = m.enc;
  const sig = m.signal;
  const srv = m.server;
  const rows: Array<{ k: string; v: string }> = [];

  // 1. Codec — H.264 High @ L4.0 (avc1.640028)  [P1 → string; SIG fallback]
  let codecRow: string;
  if (enc) {
    codecRow = `H.264 ${profileName(enc.profileIdc)} @ L${levelName(enc.levelIdc)} (${codecStringFor(enc.profileIdc, enc.levelIdc)})`;
  } else if (sig?.codec) {
    codecRow = `${sig.profile ? sig.profile[0].toUpperCase() + sig.profile.slice(1) : 'H.264'} (${sig.codec})`;
  } else {
    codecRow = dash;
  }
  // Decode path: 'avc' (avcC description + AVCC chunks — the Firefox-compatible
  // mode) vs 'annexb' (bare fallback). Always shown so a fallback is visible.
  rows.push({ k: 'codec', v: `${codecRow} · ${m.decodePath}` });

  // 2. Resolution — the TRUE decoded frame dims WebCodecs paints (L), NEVER the
  //    hardcoded signaling 1280×800. Show a "native → stepped" arrow ONLY when the
  //    encoder actually stepped resolution down (ABR tier 3): the server-reported
  //    native height (KIND_PARAMS tail) exceeds the effective encoded height. When
  //    that native signal is absent (old server) the arrow is simply dropped.  [L, P1]
  const decW = stats?.frameWidth ?? enc?.width ?? sig?.width ?? null;
  const decH = stats?.frameHeight ?? enc?.height ?? sig?.height ?? null;
  const fpsCap = enc?.fpsCap ?? sig?.fpsCap ?? null;
  const stepped = !!enc && enc.nativeHeight != null && enc.nativeHeight > enc.height;
  let resRow = stepped && enc
    ? `${enc.nativeWidth}×${enc.nativeHeight} → ${enc.width}×${enc.height}`
    : decW && decH ? `${decW}×${decH}` : dash;
  if (fpsCap) resRow += ` @${fpsCap}`;
  rows.push({ k: 'resolution', v: resRow });

  // 3. Bitrate — measured RECEIVED vs the VBV PEAK CAP. In CRF+VBV mode the server
  //    -maxrate is a ceiling, not a target, so this row reads recv / cap Mbps and a
  //    %-of-cap utilisation (measured recv over the cap).  [L recv, P1 cap]
  const capKbps = enc?.targetKbps ?? srv?.targetKbps ?? sig?.ladder?.[0]?.maxKbps ?? 0;
  const recvKbps = m.recvKbps;
  let brRow = `recv ${(recvKbps / 1000).toFixed(1)} / cap ${capKbps ? (capKbps / 1000).toFixed(1) : dash} Mbps`;
  if (capKbps > 0) brRow += `  ${Math.round((recvKbps / capKbps) * 100)}% of cap`;
  rows.push({ k: 'bitrate', v: brRow });

  // 4. FPS — decoded fps.  [L]
  rows.push({ k: 'fps', v: `${m.decodeFps.toFixed(0)}` });

  // 5. GOP / KF.  [SIG gop, P1 keyframe_ms]
  const gop = sig?.gop ?? null;
  const kfMs = enc?.keyframeMs ?? sig?.keyframeMs ?? null;
  rows.push({ k: 'gop / kf', v: `GOP ${gop ?? dash} / KF ${kfMs ?? dash} ms` });

  // 6. RTT.  [PING]
  rows.push({ k: 'rtt', v: stats?.rttMs != null ? `${stats.rttMs.toFixed(1)} ms` : `${dash} ms` });

  // 7. Loss / Drops.  [L]
  rows.push({ k: 'loss / drops', v: `PL ${m.lossPct.toFixed(1)}% / DR ${m.framesDropped} / FZ ${m.freezeCount}` });

  // 8. Decode — queue · ms/frame.  [L]
  rows.push({ k: 'decode', v: `Q ${m.decodeQueue} · ${m.decodeMs.toFixed(1)} ms/f` });

  // 8b. Idle-frame-stall watchdog (Item 4) — DISTINCT from RTT-ping liveness.  [L]
  rows.push({ k: 'video', v: m.stalled ? 'STALLED (>2s no frame)' : 'live' });

  // 8c. Decoder errors — only when any occurred (no longer swallowed).  [L]
  if (m.decodeErrors > 0) {
    const msg = m.lastDecodeError ?? '';
    rows.push({
      k: 'dec errors',
      v: `${m.decodeErrors}${msg ? ` · ${msg.length > 48 ? `${msg.slice(0, 47)}…` : msg}` : ''}`,
    });
  }

  // 9. ABR tier.  [P1 tier/crf]
  if (enc) {
    const tierName = sig?.ladder?.find((r) => r.tier === enc.tier)?.name
      ?? ['high', 'med', 'low', 'floor'][enc.tier] ?? `t${enc.tier}`;
    rows.push({ k: 'abr tier', v: `T${enc.tier} ${tierName} (CRF ${enc.crf})` });
  } else {
    rows.push({ k: 'abr tier', v: dash });
  }

  // 10. Preset / tune.  [SIG or P1 preset]
  const preset = enc ? presetName(enc.presetEnum) : (sig?.preset ?? dash);
  rows.push({ k: 'preset / tune', v: `${preset} / ${sig?.tune ?? 'zerolatency'}` });

  // 11. Scores — prefer server P2 truth, else the client-local scorer. + banner.
  const useSrv = !!srv;
  const l = useSrv ? srv!.latencyScore : m.latencyScore;
  const n = useSrv ? srv!.lossScore : m.lossScore;
  const b = useSrv ? srv!.bandwidthScore : m.bandwidthScore;
  const o = useSrv ? srv!.overallScore : m.overallScore;
  rows.push({ k: 'scores', v: `L${l} N${n} B${b} · ovr ${o} [${m.banner}]` });

  // 12. QP — only when the server reports it (≠ 0xFF).  [P2]
  if (srv && srv.qp !== 0xff) rows.push({ k: 'qp', v: `QP ${srv.qp}` });

  return rows;
}
