// ============================================================================
//  input/pointerTelemetry — PURE per-stroke / per-hover-window counters.
//  ---------------------------------------------------------------------------
//  DIAGNOSTIC telemetry (a bonus channel; the streamhost server side is the
//  primary one) for two mouse/pen-path symptoms on the abs stations (win95/98):
//    1. a CURVED S-Pen / finger drag in Paint arrives as a straight LINE —
//       intermediate move samples are being lost between the browser and the
//       guest;
//    2. the guest cursor LAGS a bare S-Pen hover.
//  Both live in useStreamInput's mouse/pen ELSE-branch (an S-Pen reports
//  pointerType 'pen', and `touchExhibit` is false on a desktop exhibit, so it
//  does NOT take the touch recognizer — see docs/lab/INPUT-DEBUGGING.md). We accumulate cheap counters over a stroke / a ~1s hover window
//  and emit ONE compact detail string per stroke / per window through
//  logClientEvent — never a per-sample event.
//
//  ALLOCATION RULE: the hot per-sample path is a pure counter bump — sample()
//  and hover() take primitives and never allocate. Only begin()/finish()/flush()
//  (once per stroke / per window) build the small JSON detail string.
//
//  DOM-free + framework-free, so the whole thing is unit-testable in isolation
//  (see pointerTelemetry.test.ts).
// ============================================================================

/** Move-datagram wire counters sampled from the StreamClient (see
 *  streamClient.moveWireSnapshot). The stroke accumulator diffs a snapshot at
 *  begin() against one at finish() to attribute wire loss to the stroke. */
export interface WireSnapshot {
  /** total move datagrams enqueued (sendMoveAbs/sendMoveRel) since client start. */
  sent: number;
  /** move-datagram write promises that later REJECTED (session gone / TTL drop). */
  rejected: number;
  /** lowest dgWriter.desiredSize sampled at enqueue (negative ⇒ backpressure),
   *  or null when no datagram has been enqueued yet. */
  desiredSizeMin: number | null;
}

/** A stroke endpoint: guest-pixel coords + the event timeStamp (ms). */
export interface StrokePoint {
  x: number;
  y: number;
  t: number;
}

/** Which native handler delivered a move event — the pointermove-vs-
 *  pointerrawupdate source gate is the prime suspect for the lost samples. */
export type NativeMoveType = 'pointermove' | 'pointerrawupdate';

const HOVER_WINDOW_MS = 1000; // emit one hover-tel per ~1s of active hovering

/**
 * Per-stroke accumulator. One instance is reused across strokes (begin() resets
 * the counters); sample() is a pure bump so a fast drag adds no per-sample GC
 * pressure. finish() returns a compact JSON detail string for logClientEvent,
 * or null when no stroke was active (a stray up without a matching down).
 */
// Bounded raw-point store: a circle→line diagnosis needs the SHAPE, not just the
// counts. We track two bounding boxes — the guest-px path (bbox: what the guest is
// told to draw) and the raw client-px path (rbox: what the browser handed the app,
// BEFORE letterbox mapping) — plus a downsampled polyline. bbox height≈0 with width
// large = a horizontal line; rbox flat too ⇒ the vertical motion was lost at the
// pen/browser (e.g. a scroll/pan gesture ate it); rbox 2D but bbox flat ⇒ the
// clientToGuest mapping flattened Y.
const MAX_STORE = 4096; // hard cap on stored path points (bbox keeps updating past it)
const PATH_OUT = 16;    // downsampled waypoints emitted in the detail
const DETAIL_BUDGET = 480; // keep the JSON under logClientEvent's 512 cap (valid JSON)

interface Box { minX: number; minY: number; maxX: number; maxY: number }
const newBox = (): Box => ({ minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity });
const grow = (b: Box, x: number, y: number): void => {
  if (x < b.minX) b.minX = x;
  if (x > b.maxX) b.maxX = x;
  if (y < b.minY) b.minY = y;
  if (y > b.maxY) b.maxY = y;
};
const boxArr = (b: Box): number[] | null =>
  b.minX === Infinity ? null : [Math.round(b.minX), Math.round(b.minY), Math.round(b.maxX), Math.round(b.maxY)];

export class StrokeAccumulator {
  private active = false;
  private pt = '';
  private start: StrokePoint = { x: 0, y: 0, t: 0 };
  private wire0: WireSnapshot = { sent: 0, rejected: 0, desiredSizeMin: null };
  private rawFires = 0;   // # pointerrawupdate handler fires
  private moveFires = 0;  // # pointermove handler fires
  private forwarded = 0;  // total samples actually sent to the guest
  private coalesced = 0;  // sum of resolved (getCoalescedEvents) sample counts
  private gBox = newBox(); // guest-px bounding box of forwarded points
  private rBox = newBox(); // raw client-px bounding box of forwarded points
  private px: number[] = []; // guest-px path (flat x,y … bounded by MAX_STORE)
  private py: number[] = [];
  private pb: number[] = []; // native.buttons bitmask at each stored path point
  // Per-move button accounting: is a button actually held while the cursor moves?
  private heldEv = 0;    // forwarding move events with a button held (buttons != 0)
  private freeEv = 0;    // forwarding move events with NO button (buttons === 0)
  private btnFlips = 0;  // times the buttons bitmask changed mid-stroke (flicker!)
  private firstBtn = -1; // buttons on the first forwarded move
  private lastBtn = -1;

  /** Open a stroke on pointer DOWN. `wire` is a fresh moveWireSnapshot(). */
  begin(pointerType: string, start: StrokePoint, wire: WireSnapshot): void {
    this.active = true;
    this.pt = pointerType;
    this.start = start;
    this.wire0 = wire;
    this.rawFires = 0;
    this.moveFires = 0;
    this.forwarded = 0;
    this.coalesced = 0;
    this.gBox = newBox();
    this.rBox = newBox();
    this.px.length = 0;
    this.py.length = 0;
    this.pb.length = 0;
    this.heldEv = 0;
    this.freeEv = 0;
    this.btnFlips = 0;
    this.firstBtn = -1;
    this.lastBtn = -1;
  }

  /** Record ONE native move event (called once per forwardMove, NOT per
   *  coalesced sample): its source handler, the number of samples it resolved
   *  to, and how many of those were forwarded to the guest. The optional
   *  gx,gy / cx,cy are the last forwarded sample's guest-px and raw client-px
   *  coords (fed only when forwarded>0), for the shape boxes/path. No-ops when
   *  no stroke is active (bare hover feeds HoverAccumulator instead). */
  sample(
    nativeType: NativeMoveType, coalescedLen: number, forwarded: number,
    gx?: number, gy?: number, cx?: number, cy?: number, buttons?: number,
  ): void {
    if (!this.active) return;
    if (nativeType === 'pointerrawupdate') this.rawFires++;
    else this.moveFires++;
    this.coalesced += coalescedLen;
    this.forwarded += forwarded;
    // Per-move button accounting — only for events that actually forwarded a move.
    if (forwarded > 0 && buttons !== undefined) {
      if (this.firstBtn < 0) this.firstBtn = buttons;
      if (buttons !== this.lastBtn) {
        if (this.lastBtn >= 0) this.btnFlips++;
        this.lastBtn = buttons;
      }
      if (buttons === 0) this.freeEv++; else this.heldEv++;
    }
    if (gx !== undefined && gy !== undefined) {
      grow(this.gBox, gx, gy);
      if (this.px.length < MAX_STORE) {
        this.px.push(gx);
        this.py.push(gy);
        this.pb.push(buttons ?? -1);
      }
    }
    if (cx !== undefined && cy !== undefined) grow(this.rBox, cx, cy);
  }

  /** Close the stroke on pointer UP/cancel; `wire` is a fresh moveWireSnapshot().
   *  Returns the drag-tel detail string, or null if no stroke was open. */
  finish(end: StrokePoint, wire: WireSnapshot): string | null {
    if (!this.active) return null;
    this.active = false;
    const rec: Record<string, unknown> = {
      pt: this.pt,
      durMs: Math.round(end.t - this.start.t),
      raw: this.rawFires,
      move: this.moveFires,
      fwd: this.forwarded,
      coal: this.coalesced,
      dg: wire.sent - this.wire0.sent,             // datagrams enqueued this stroke
      rej: wire.rejected - this.wire0.rejected,    // …that later rejected
      dsMin: wire.desiredSizeMin,                  // lowest desiredSize (≤0 ⇒ backpressure)
      btnHeld: this.heldEv,                        // move events with a button held
      btnFree: this.freeEv,                        // move events with NO button (should be 0 in a drag)
      btnFlips: this.btnFlips,                      // buttons-mask changes mid-stroke (>0 ⇒ contact flicker)
      btn0: this.firstBtn,                         // buttons bitmask on the first forwarded move
      bbox: boxArr(this.gBox),                     // guest-px shape [minX,minY,maxX,maxY]
      rbox: boxArr(this.rBox),                     // raw client-px shape (pre-mapping)
      from: [Math.round(this.start.x), Math.round(this.start.y)],
      to: [Math.round(end.x), Math.round(end.y)],
      path: this.downsample(),                     // guest-px polyline [x,y,buttons] (≤PATH_OUT pts)
    };
    let out = JSON.stringify(rec);
    if (out.length > DETAIL_BUDGET) { delete rec.path; out = JSON.stringify(rec); } // keep valid JSON
    return out;
  }

  /** Stride-downsample the stored path to ≤PATH_OUT waypoints as [x,y,buttons],
   *  always including the final point so the shape's extent + the button state at
   *  the end are preserved. buttons at each point reveals whether the drag stayed
   *  held ([.,.,1]) or dropped contact ([.,.,0]) partway round the curve. */
  private downsample(): number[][] {
    const n = this.px.length;
    if (n === 0) return [];
    const stride = Math.max(1, Math.ceil(n / PATH_OUT));
    const out: number[][] = [];
    for (let i = 0; i < n; i += stride) {
      out.push([Math.round(this.px[i]), Math.round(this.py[i]), this.pb[i]]);
    }
    const li = n - 1;
    const lx = Math.round(this.px[li]), ly = Math.round(this.py[li]);
    const last = out[out.length - 1];
    if (!last || last[0] !== lx || last[1] !== ly) out.push([lx, ly, this.pb[li]]);
    return out;
  }
}

/**
 * Per-hover-window accumulator for bare S-Pen hover (buttons === 0). Counts the
 * hover events SEEN vs the ones FORWARDED (allowPenHover throttles abs-station
 * hover to a 32ms ≈ 30Hz ceiling), so the effective forwarded Hz over the
 * window is visible against that ceiling. Emits about once per second of active
 * hovering; a partial trailing window is simply dropped.
 */
export class HoverAccumulator {
  private open = false;
  private t0 = 0;
  private seen = 0;
  private forwarded = 0;

  /** Open a window at t0 if one is not already open (idempotent — the call site
   *  can invoke it on every hover event without tracking window state itself). */
  newWindow(t0: number): void {
    if (this.open) return;
    this.open = true;
    this.t0 = t0;
    this.seen = 0;
    this.forwarded = 0;
  }

  /** Count one bare-hover native event within the open window. */
  hover(forwarded: boolean): void {
    if (!this.open) return;
    this.seen++;
    if (forwarded) this.forwarded++;
  }

  /** Emit + close the window once it spans ~1s; else null (keep accumulating). */
  flush(t1: number): string | null {
    if (!this.open) return null;
    const windowMs = t1 - this.t0;
    if (windowMs < HOVER_WINDOW_MS) return null;
    this.open = false;
    return JSON.stringify({
      hoverSeen: this.seen,
      hoverForwarded: this.forwarded,
      windowMs: Math.round(windowMs),
    });
  }
}
