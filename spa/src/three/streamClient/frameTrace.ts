// ============================================================================
//  three/streamClient/frameTrace — the RETURN half of the sampled-input trace
//  (docs/lab/TRACE-CONTEXT.md §3.2/§8.1). `input.edge` -> `input.dispatch` ->
//  `guest.frame.next` -> `transport.frame.next` stops at the daemon's own
//  transport send; this module closes it with `client.frame.receive` /
//  `client.frame.decode` / `client.frame.paint`, siblings of the two daemon
//  spans above under the same `input.dispatch` — AND it closes the trace's own
//  ROOT, because `input.edge`'s duration is defined as the edge → painted-pixel
//  round trip and the paint happens here.
//  ---------------------------------------------------------------------------
//  HOW THE CLIENT LEARNS WHICH FRAME ANSWERED ITS INPUT. This tab cannot know
//  on its own — WebCodecs hands back a `frame.timestamp` (the AU's capture
//  clock), never "this was the effect of edge X". The daemon is the only
//  place that knows (`trace_session.rs::effect_sent`), so it mints a tiny
//  out-of-band wire message naming the `frame_id` and the trace/span to
//  answer with (KIND_PARAMS subtype 3, `transport/egress.rs::
//  spawn_frame_mark`) — `noteFrameMark` below is the client half, called from
//  `videoDecode.ts`'s KIND_PARAMS dispatch.
//
//  EXPLICIT ID, NEVER ORDERING. The mark and the AU it names travel on two
//  INDEPENDENT uni-streams the network is free to reorder against each other
//  — the mark is not guaranteed to arrive before, with, or after its frame.
//  So this module never assumes "the next frame I paint answered the last
//  edge I sent" — that approximation is exactly what fails under the load,
//  drops and reordering that make the measurement worth taking in the first
//  place. It keeps two small bounded FIFOs — recent per-frame timestamps, and
//  marks that arrived before their frame — and matches strictly by
//  `frame_id`, whichever side completes second.
//
//  COST. The overwhelming majority of frames are never the answer to a
//  sampled edge; each still costs one `Map.set` + a bounded-size check as it
//  passes through `noteReceived`/`noteDecodeSubmit` — no allocation beyond
//  the entry, no hex encoding, no span. A span is only ever built for a frame
//  that BOTH finished painting AND was marked, which is bounded by the input
//  side's own qualifying-edge rule (`inputTrace.ts`) — never per frame.
// ============================================================================
import { emitSpan } from '../../analytics/trace';
import { settleEdge } from './inputTrace';

interface FrameTiming {
  receiveMs: number;
  decodeStartMs: number;
  decodeEndMs?: number;
  paintEndMs?: number;
}

interface Mark {
  traceId: string;
  spanId: string;
  /** `kh.station.id` — the SAME key `analytics/stationAttrs.ts` uses for
   *  every other station-scoped span/flow (landed 2026-08-31, station-type
   *  grouping). This module only ever has the bare station id on hand
   *  (`StreamClient.stationId`) — `emulatorFamily`/`ui`/`resetMode` live on
   *  the resolved manifest row a layer above the decode pipeline and are not
   *  threaded this deep; a caller wanting them can join on this id. */
  stationId: string | null;
}

/** Bounds memory, not a working set: `guest.frame.next` fires on the very
 *  next encoded AU after injection, so a mark's frame is normally within a
 *  handful of frame_ids of the ones already tracked. This is headroom for
 *  reordering and jitter, not a queue depth normal operation approaches. A
 *  frame_id or mark that ages out unmatched simply never gets a client span
 *  — the daemon's half of the trace still stands on its own. */
const MAX_TRACKED = 64;

const timings = new Map<number, FrameTiming>(); // frameId -> timing
const timingOrder: number[] = []; // FIFO insertion order, for bounded eviction
const tsToFrameId = new Map<number, number>(); // capture ts -> frameId (the decoder's own join key)
const tsOrder: number[] = [];
const marks = new Map<number, Mark>(); // frameId -> daemon-named answer context
const markOrder: number[] = [];

function evictOldest<K>(map: Map<K, unknown>, order: K[], max: number): void {
  while (order.length > max) {
    const old = order.shift();
    if (old !== undefined) map.delete(old);
  }
}

/** The AU's bytes arrived off the wire — called once per video AU, from
 *  `feedVideoAUImpl`, regardless of whether it turns out to be sampled. */
export function noteReceived(frameId: number, atMs: number): void {
  if (!timings.has(frameId)) timingOrder.push(frameId);
  timings.set(frameId, { receiveMs: atMs, decodeStartMs: atMs });
  evictOldest(timings, timingOrder, MAX_TRACKED);
}

/** The AU was just handed to `VideoDecoder.decode()` — called once per AU
 *  that reaches the decoder (a stale or gated AU never gets here, and never
 *  needs to: `noteFrameMark` below just ages out unmatched). `ts` is the
 *  `EncodedVideoChunk`/`VideoFrame` timestamp WebCodecs threads through to
 *  the output callback — the only join key that callback has. */
export function noteDecodeSubmit(frameId: number, ts: number, atMs: number): void {
  const t = timings.get(frameId);
  if (t) t.decodeStartMs = atMs;
  if (!tsToFrameId.has(ts)) tsOrder.push(ts);
  tsToFrameId.set(ts, frameId);
  evictOldest(tsToFrameId, tsOrder, MAX_TRACKED);
}

/** The decoder produced this frame (`decodeEndMs`) and it was handed to the
 *  paint sink (`paintEndMs`) — both from the SAME synchronous output
 *  callback in `videoDecode.ts`, which is where `ts` (`frame.timestamp`) is
 *  the only thing WebCodecs gives back. */
export function noteDecoded(ts: number, decodeEndMs: number, paintEndMs: number): void {
  const frameId = tsToFrameId.get(ts);
  if (frameId === undefined) return;
  const t = timings.get(frameId);
  if (!t) return;
  t.decodeEndMs = decodeEndMs;
  t.paintEndMs = paintEndMs;
  maybeEmit(frameId);
}

/** The daemon named `frameId` as the answer to a sampled input edge
 *  (KIND_PARAMS subtype 3). May arrive before OR after this tab finishes
 *  painting that frame — both orders are handled the same way, by matching
 *  on `frameId` in `maybeEmit`. */
export function noteFrameMark(
  frameId: number, traceId: string, spanId: string, stationId: string | null,
): void {
  if (!marks.has(frameId)) markOrder.push(frameId);
  marks.set(frameId, { traceId, spanId, stationId });
  evictOldest(marks, markOrder, MAX_TRACKED);
  maybeEmit(frameId);
}

/** Emit the three return-path spans once BOTH halves are in: the frame
 *  finished its client-side journey (paint recorded) AND the daemon has
 *  named it as a sampled edge's answer. Consumes both entries so a frame_id
 *  is never double-emitted (frame_id counters wrap per encoder session —
 *  `abr.rs`'s own comment on the same field — so leaving a stale match
 *  around risks a wrapped id reusing it). */
function maybeEmit(frameId: number): void {
  const t = timings.get(frameId);
  const m = marks.get(frameId);
  if (!t || !m || t.decodeEndMs === undefined || t.paintEndMs === undefined) return;
  const attrs = m.stationId ? { 'kh.station.id': m.stationId } : undefined;
  emitSpan(
    m.traceId, m.spanId, 'client.frame.receive',
    t.receiveMs, Math.max(0, t.decodeStartMs - t.receiveMs), attrs,
  );
  emitSpan(
    m.traceId, m.spanId, 'client.frame.decode',
    t.decodeStartMs, Math.max(0, t.decodeEndMs - t.decodeStartMs), attrs,
  );
  emitSpan(
    m.traceId, m.spanId, 'client.frame.paint',
    t.decodeEndMs, Math.max(0, t.paintEndMs - t.decodeEndMs), attrs,
  );
  // AND THE ROOT'S OWN DURATION. `input.edge` was left OPEN when the edge was
  // sampled precisely so it could be closed HERE, at the paint — so the root of
  // an input trace measures the visitor-facing edge → painted-pixel round trip
  // rather than the millisecond it took to hand a record to a stream writer.
  // Both ends are `performance.now()` readings from THIS tab, which is why the
  // number needs no clock agreement between the two machines
  // (`inputTrace.ts::settleEdge`). A no-op when the mark outlived its edge
  // entry, in which case the rest of the trace is unaffected.
  settleEdge(m.traceId, t.paintEndMs);
  timings.delete(frameId);
  marks.delete(frameId);
}

/** Big-endian bytes -> lowercase hex, matching how `traceparent` (and
 *  `input_trace.rs`'s own suffix) already spell a trace/span id — no
 *  endian conversion needed, just a byte-for-byte hex render in the order
 *  the wire already carries them. */
export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Test seam: production never needs this, the maps free-run for the tab's
 *  life bounded by `MAX_TRACKED`. */
export function __resetFrameTrace(): void {
  timings.clear(); timingOrder.length = 0;
  tsToFrameId.clear(); tsOrder.length = 0;
  marks.clear(); markOrder.length = 0;
}
