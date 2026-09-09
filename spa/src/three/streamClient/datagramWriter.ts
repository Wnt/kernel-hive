// ============================================================================
//  streamClient/datagramWriter — open the OUTGOING datagram writer on whichever
//  of the two WebTransport datagram API shapes this browser implements.
//  ---------------------------------------------------------------------------
//  The W3C WebTransport spec moved the write side of datagrams off the duplex
//  stream: `WebTransportDatagramDuplexStream` now carries `readable` plus
//  `createWritable(options)`, which returns a `WebTransportDatagramsWritable`
//  that owns `sendGroup`/`sendOrder` AND the outgoing knobs
//  (`outgoingMaxAge`, `outgoingHighWaterMark`). The old shape kept a
//  `writable` attribute and the knobs on the duplex stream itself.
//
//  Chrome (150, 2026-09) still exposes the legacy `writable`. Safari 26 (iOS
//  18.7, `Version/26.6.1 Mobile Safari`) implements ONLY the spec shape, so
//  `wt.datagrams.writable` is `undefined` there and the first write-side call
//  threw inside connect() — AFTER `ready` had settled and `connect` had been
//  logged as "transport ok" — burning all four ladder attempts on every
//  station and sending the walk-in guest to the poster fallback
//  (clientlog sessions c0616c72/d3fca1dc, 2026-09-08). Feature-detect, never
//  assume: a UA that ships both is served by the spec method.
// ============================================================================

/** Which datagram write API the browser offered. `createWritable` is the
 *  current spec; `writable` is the legacy attribute Chromium still carries. */
type DatagramApi = 'createWritable' | 'writable';

/** Where `outgoingMaxAge` was accepted: the spec's writable object, the legacy
 *  duplex stream, or nowhere (a UA without the knob simply ignores it). */
type MaxAgeOwner = 'writable' | 'duplex' | 'none';

export interface DatagramWriterFacts {
  api: DatagramApi;
  maxAgeOn: MaxAgeOwner;
}

/** Both shapes, structurally. lib.dom only knows the legacy `writable`;
 *  `createWritable` is typed here so the spec path is not an `any` escape. */
export type DatagramDuplexLike = {
  readable?: ReadableStream<Uint8Array>;
  writable?: WritableStream<Uint8Array>;
  createWritable?: (options?: { sendGroup?: unknown; sendOrder?: number }) => WritableStream<Uint8Array>;
  outgoingMaxAge?: number | null;
};

/** Pointer-move datagrams older than this in the send queue are expired rather
 *  than delivered late (bufferbloat guard). Spec'd but not implemented
 *  everywhere — the assignment never throws out of here. */
export const OUTGOING_MAX_AGE_MS = 100;

export function openDatagramWriter(dg: DatagramDuplexLike): {
  writer: WritableStreamDefaultWriter<Uint8Array>;
  facts: DatagramWriterFacts;
} {
  const spec = typeof dg.createWritable === 'function';
  const out = spec ? dg.createWritable?.() : dg.writable;
  if (!out || typeof out.getWriter !== 'function') {
    throw new TypeError('WebTransport datagrams expose neither createWritable() nor writable');
  }
  const writer = out.getWriter() as WritableStreamDefaultWriter<Uint8Array>;
  // The knob lives on the object that owns the outgoing queue: the
  // WebTransportDatagramsWritable on the spec shape, the duplex stream on the
  // legacy one. Both are tried, each fenced, and "took" is judged by the
  // attribute EXISTING before the write — a UA without it would accept the
  // assignment as a plain expando and read as a success otherwise.
  let maxAgeOn: MaxAgeOwner = 'none';
  if (spec && setMaxAge(out as { outgoingMaxAge?: number | null })) maxAgeOn = 'writable';
  else if (setMaxAge(dg)) maxAgeOn = 'duplex';
  return { writer, facts: { api: spec ? 'createWritable' : 'writable', maxAgeOn } };
}

function setMaxAge(o: { outgoingMaxAge?: number | null }): boolean {
  try {
    if (!('outgoingMaxAge' in o)) return false;
    o.outgoingMaxAge = OUTGOING_MAX_AGE_MS;
    return o.outgoingMaxAge === OUTGOING_MAX_AGE_MS;
  } catch { return false; }
}
