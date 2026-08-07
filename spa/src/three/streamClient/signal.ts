// ============================================================================
//  streamClient/signal — fetch + normalize the streamhost signaling doc.
//  ---------------------------------------------------------------------------
//  SIGNALING (replaces neko's WS message soup): fetch one small JSON/text doc
//  from the tile's signal endpoint → { url, certHash(b64), wireVersion?, audio? }.
//  The cert hash is fetched LIVE every connect (never pinned) because streamhost
//  certs are self-signed ECDSA P-256 with a <14-day validity and rotate ~every
//  10 days (Chrome refuses serverCertificateHashes on certs >14 days out).
// ============================================================================

import type { StreamhostSignal, StreamVideoParams, StreamLadderRung } from './types';

/** Decode a base64 string to a fresh ArrayBuffer of its bytes. */
function b64ToBytes(b64: string): ArrayBuffer {
  const bin = atob(b64.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

/**
 * Fetch + normalize the signaling doc. Accepts either a JSON object (preferred)
 * or a bare base64 hash string (the prototype's hash-file). Tolerates several
 * field spellings so the SPA and the Rust server can evolve independently.
 */
export async function fetchSignal(signalEndpoint: string): Promise<StreamhostSignal> {
  const res = await fetch(signalEndpoint, { cache: 'no-store', mode: 'cors' });
  if (!res.ok) throw new Error(`signal ${res.status} @ ${signalEndpoint}`);
  const text = (await res.text()).trim();

  let doc: Record<string, unknown> | null = null;
  try { doc = JSON.parse(text); } catch { /* not JSON — keep null */ }

  if (!doc || typeof doc !== 'object') {
    // Bare base64 hash file → derive the WT url from the signal endpoint's host.
    const u = new URL(signalEndpoint);
    const url = `https://${u.hostname}:${u.port || '443'}/wt`;
    return { url, certHash: b64ToBytes(text), wireVersion: 1, audio: false };
  }

  const hashB64 =
    (doc.certHashB64 ?? doc.certHash ?? doc.hashB64 ?? doc.hash) as string | undefined;
  if (!hashB64) throw new Error('signal doc missing cert hash');

  let url = doc.url as string | undefined;
  if (!url) {
    const host = (doc.host as string | undefined) ?? new URL(signalEndpoint).hostname;
    const port = (doc.udpPort ?? doc.port) as number | string | undefined;
    const path = (doc.path as string | undefined) ?? '/wt';
    if (!port) throw new Error('signal doc missing url and host/port');
    url = `https://${host}:${port}${path.startsWith('/') ? path : `/${path}`}`;
  }

  return {
    url,
    certHash: b64ToBytes(hashB64),
    // The production streamhost server is tagged wire (1-byte KIND prefix on
    // every uni-stream). wireVersion>=3 additionally understands KIND_PARAMS +
    // the connect-time `video` object. The JSON signal doc may omit wireVersion,
    // so default to 3 (safe: KIND_PARAMS/T_STATS are additive and a server that
    // never sends them still works). Only the bare-hash page (handled above) is v1.
    wireVersion: Number(doc.wireVersion ?? 3) || 3,
    audio: doc.audio !== false,
    video: parseVideoParams(doc.video),
    quic: parseQuicParams(doc.quic),
  };
}

function parseQuicParams(v: unknown): StreamhostSignal['quic'] | undefined {
  if (!v || typeof v !== 'object') return undefined;
  const o = v as Record<string, unknown>;
  const maxUdpPayloadSize = typeof o.maxUdpPayloadSize === 'number'
    && Number.isFinite(o.maxUdpPayloadSize)
    ? o.maxUdpPayloadSize
    : undefined;
  const mtuDiscovery = typeof o.mtuDiscovery === 'boolean' ? o.mtuDiscovery : undefined;
  if (maxUdpPayloadSize == null && mtuDiscovery == null) return undefined;
  return { maxUdpPayloadSize, mtuDiscovery };
}

/** Normalize the signaling `video` object; tolerant of missing fields. */
function parseVideoParams(v: unknown): StreamVideoParams | undefined {
  if (!v || typeof v !== 'object') return undefined;
  const o = v as Record<string, unknown>;
  const num = (x: unknown): number | undefined =>
    typeof x === 'number' && Number.isFinite(x) ? x : undefined;
  const str = (x: unknown): string | undefined => (typeof x === 'string' ? x : undefined);
  let ladder: StreamLadderRung[] | undefined;
  if (Array.isArray(o.ladder)) {
    ladder = o.ladder
      .map((r) => {
        const rr = r as Record<string, unknown>;
        const tier = num(rr.tier);
        if (tier == null) return null;
        return {
          tier,
          name: str(rr.name) ?? `t${tier}`,
          crf: num(rr.crf) ?? 0,
          maxKbps: num(rr.maxKbps) ?? 0,
          minHeight: num(rr.minHeight),
        } as StreamLadderRung;
      })
      .filter((r): r is StreamLadderRung => r != null);
  }
  return {
    codec: str(o.codec),
    profile: str(o.profile),
    preset: str(o.preset),
    tune: str(o.tune),
    width: num(o.width),
    height: num(o.height),
    fpsCap: num(o.fpsCap),
    keyframeMs: num(o.keyframeMs),
    gop: num(o.gop),
    defaultTier: num(o.defaultTier),
    ladder,
  };
}
