// ============================================================================
//  streamClient/analyticsEvents — the stream client's call sites for the
//  analytics event vocabulary (`analytics/streamEvents.ts`).
//  ---------------------------------------------------------------------------
//  WHY A SEPARATE FILE, the same reason `connectTelemetry.ts` and
//  `recoverTelemetry.ts` are separate from the hook they instrument: the
//  modules these events come from (`videoDecode.ts`, `abr.ts`, `transport.ts`,
//  `audioPlayer.ts`) are load-bearing stream code sitting on or near the
//  repo's file-size caps, and every measurement added directly to them is a
//  negotiation with the size budget settled by deleting comments from code
//  that has nothing to do with the measurement. So each of those files gains
//  ONE named call, and the reasoning about what the event means lives here and
//  in the taxonomy.
//
//  NOTHING HERE DECIDES ANYTHING. No sampling (the taxonomy owns it), no
//  vendor calls (the adapter owns those), no thresholds. These functions read
//  state the stream code already computed for its own purposes and name it.
//  If one of them ever needs a rule of its own, the rule belongs in the module
//  that owns the fact, not here.
// ============================================================================

import { emitStreamEvent } from '../../analytics/streamEvents';
import type { Attrs } from '../../analytics/trace';
import type { StreamEncoderParams } from './types';

/** Station id as a span attribute, matching `analytics/stationAttrs.ts`'s key
 *  exactly so a query means the same thing here as it does on a flow span.
 *  The other station dimensions (emulator family, ui kind, reset mode) come
 *  from the manifest and are not reachable from inside the stream client —
 *  they are on the surrounding `station.connect` span this event nests under,
 *  which is why the drilldown still has them. */
function station(stationId: string | null): Attrs {
  return stationId ? { 'kh.station.id': stationId } : {};
}

/** Per-client time of the last quality switch, so the flap metric can be a
 *  real interval. A WeakMap rather than a field on StreamClient: this is
 *  instrumentation state, and a disposed client must not be kept alive by it. */
const lastSwitchAt = new WeakMap<object, number>();

/**
 * A KIND_PARAMS encoder-params record changed the quality in force.
 *
 * The FIRST record of a session is not a switch — it is the session learning
 * what it is already being sent — so it seeds the interval and emits nothing.
 * Reporting it would put one sample per session into the flap distribution at
 * whatever interval the params happened to arrive, which is a statement about
 * connect timing wearing the flap metric's name.
 */
export function noteQualitySwitch(
  client: object,
  prev: StreamEncoderParams | null | undefined,
  next: StreamEncoderParams,
  stationId: string | null,
): void {
  const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
  const previousAt = lastSwitchAt.get(client);
  lastSwitchAt.set(client, now);
  if (!prev) return;
  const changed = prev.tier !== next.tier
    || prev.crf !== next.crf
    || prev.targetKbps !== next.targetKbps;
  if (!changed) return;
  // A short stable token, never a sentence: `error.type`-style grouping is
  // the whole reason a reason field is worth having.
  const reason = prev.tier === next.tier
    ? 'rate'
    : next.tier > prev.tier ? 'down' : 'up';
  emitStreamEvent('stream.quality.switch', {
    ...station(stationId),
    'kh.quality.tierFrom': prev.tier,
    'kh.quality.tierTo': next.tier,
    'kh.quality.crfFrom': prev.crf,
    'kh.quality.crfTo': next.crf,
    'kh.quality.targetKbps': next.targetKbps,
    'kh.quality.width': next.width,
    'kh.quality.height': next.height,
    'kh.quality.fpsCap': next.fpsCap,
    'kh.quality.reason': reason,
  }, previousAt === undefined ? undefined : Math.round(now - previousAt));
}

/** A configure/decode failure. `fatal` is the latched `decoderFailed` state —
 *  the difference between a bad frame and a dead decoder. */
export function noteDecodeError(input: {
  message: string;
  consecutive: number;
  total: number;
  path: string;
  fatal: boolean;
  stationId: string | null;
}): void {
  emitStreamEvent('stream.decode.error', {
    ...station(input.stationId),
    // OTel's own attribute for "what KIND of fault", so a trace UI groups
    // decode failures by type rather than by message text.
    'error.type': input.message.slice(0, 80),
    'kh.decode.consecutive': input.consecutive,
    'kh.decode.total': input.total,
    'kh.decode.path': input.path,
    'kh.decode.fatal': input.fatal,
  }, input.consecutive);
}

/** The silent-stall decoder rebuild (AUs arriving, no output, no error). */
export function noteDecoderRebuild(n: number, max: number, stationId: string | null): void {
  emitStreamEvent('stream.decode.rebuild', {
    ...station(stationId),
    'kh.decode.rebuild': n,
    'kh.decode.rebuildMax': max,
  });
}

/** A frame_id gap armed the decode gate. Sampled 1-in-10 by the taxonomy. */
export function noteFrameGap(frames: number, stationId: string | null): void {
  emitStreamEvent('stream.keyframe.gap', {
    ...station(stationId),
    'kh.keyframe.gapFrames': frames,
  }, frames);
}

/** The frame watchdog latched: no decoded frame for well past the threshold
 *  while the transport still looked open. The LATCH edge only. */
export function noteStallLatched(input: {
  thresholdMs: number;
  sinceLastPaintMs: number;
  hadDecodeError: boolean;
  stationId: string | null;
}): void {
  emitStreamEvent('stream.stall.detected', {
    ...station(input.stationId),
    'kh.stall.thresholdMs': Math.round(input.thresholdMs),
    'kh.stall.hadDecodeError': input.hadDecodeError,
  }, Math.round(input.sinceLastPaintMs));
}

/** The WebTransport session ended. `reason` is one of the client's own exit
 *  tokens (`server-finished`, `transport-down`, `connect-failed`), never the
 *  underlying error text — that is /clientlog's job and it already has it. */
export function noteTransportClosed(reason: string, stationId: string | null): void {
  emitStreamEvent('stream.transport.closed', {
    ...station(stationId),
    'kh.transport.reason': reason,
  });
}

/** The first Opus sample actually scheduled onto a running context. */
export function noteAudioStart(sinceSetupMs: number, sampleRate: number, ctxState: string): void {
  emitStreamEvent('stream.audio.start', {
    'kh.audio.sampleRate': sampleRate,
    'kh.audio.ctxState': ctxState,
  }, Math.round(sinceSetupMs));
}

/** Audio was asked for and did not start: autoplay policy, or a context that
 *  refused to resume. The visitor is watching a silent machine. */
export function noteAudioBlocked(ctxState: string, errorType: string): void {
  emitStreamEvent('stream.audio.blocked', {
    'kh.audio.ctxState': ctxState,
    'error.type': errorType.slice(0, 80),
  });
}
