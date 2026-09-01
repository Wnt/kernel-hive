// ============================================================================
//  three/streamClient/inputWire — the browser→daemon INPUT record encoders.
//  ---------------------------------------------------------------------------
//  Compact little-endian records, matching streamhost/src/input.rs:
//    datagrams (unreliable, high-rate, < ~200 B so they fit path MTU):
//      type 1  mouse move ABSOLUTE : u16 x, u16 y, u32 cseq  (guest needs usb-tablet)
//      type 4  mouse move RELATIVE : i16 dx, i16 dy          (PS/2-only guests)
//      type 7  re-home hint        : (no payload)            (rel-bridge stations)
//    per-CLASS reliable QUIC streams (Moonlight-style HOL avoidance):
//      ICLASS_BUTTON=2 → type 2  button : u8 button, u8 down, u16 x, u16 y, u32 cseq
//      ICLASS_WHEEL=3  → type 5  wheel  : i16 dx, i16 dy
//
//  THE CLIENT IS AUTHORITATIVE OVER POINTER STATE, and `cseq` is how it says so.
//  Moves ride unreliable datagrams and buttons ride a reliable stream — two
//  transports the network is free to REORDER against each other, and only one of
//  which can drop. A press therefore used to race its own position: when the
//  button won, the daemon pressed at the PREVIOUS point and then slid the cursor
//  to the real one with the button held, which the guest reads as a drag
//  (measured on IRIX, 2026-08-05; see docs/lab/PEN-TAP-PLAN.md). Two properties
//  fix it here rather than with a server-side delay:
//    * a button record CARRIES the position it happens at, so a press is one
//      atomic reliable record that can never be separated from its coordinates;
//    * every position-bearing record carries a monotonic `cseq`, so the daemon
//      can DROP an absolute move the client emitted before something it has
//      already applied, instead of rewinding the cursor under a held button.
//  Relative moves deliberately carry no cseq: deltas accumulate, so a late one
//  is still owed to the guest and dropping it would lose motion.
// ============================================================================
import { recordWireMove } from '../../input/pointerRecorder';
import { countClick, countKeystroke } from '../usageStats';
import { reach } from '../../analytics';
import {
  ICLASS_BUTTON, ICLASS_KEY, ICLASS_WHEEL, T_BUTTON, T_HINT, T_KEY, T_MOVE_ABS, T_MOVE_REL, T_WHEEL,
} from './constants';
import { maybeSampleEdge, traceSuffix, withSuffix, keyClass, writeTraced } from './inputTrace';

/** The parts of StreamClient these encoders touch. */
export interface StreamClientLike {
  cseq: number;
  /** The station this edge belongs to, or null when the caller gave none
   *  (`StreamClient.stationId`, from `cfg.osId`). Carried into a sampled
   *  edge's meta only — never into the wire record. */
  stationId: string | null;
  /** Last absolute position this client PUT ON THE WIRE, or null while none ever
   *  was. Nullable on purpose: it is a cache of something the client said, and a
   *  cache that has never been filled must be able to say so — see sendButtonImpl. */
  lastAbsX: number | null;
  lastAbsY: number | null;
  moveSent: number;
  moveRejected: number;
  moveDesiredMin: number;
  dgWriter: WritableStreamDefaultWriter<Uint8Array> | null;
  writeDatagram(b: Uint8Array): void;
  writeReliableClass(cls: number, rec: Uint8Array): void;
  noteMoveWire(): void;
  nextCseq(): number;
}

const clampU16 = (v: number) => Math.max(0, Math.min(65535, Math.round(v)));
const clampI16 = (v: number) => Math.max(-32768, Math.min(32767, Math.round(v)));

export function sendMoveAbsImpl(c: StreamClientLike, x: number, y: number) {
    const b = new Uint8Array(9); b[0] = T_MOVE_ABS;
    const dv = new DataView(b.buffer);
    const cx = clampU16(x), cy = clampU16(y);
    dv.setUint16(1, cx, true);
    dv.setUint16(3, cy, true);
    const cseq = c.nextCseq();
    dv.setUint32(5, cseq, true);
    // The authoritative cursor position, for any button that follows without one
    // of its own (a tap releases where it pressed, so it sends no fresh point).
    c.lastAbsX = cx; c.lastAbsY = cy;
    c.noteMoveWire();
    c.writeDatagram(b);
    recordWireMove(cx, cy, cseq);
  }
/** Re-home HINT (type 7, no payload): tells a relative-pointer station's bridge
 *  that the browser pointer may have moved without it seeing (tab became
 *  visible, window focus, pointer re-entered the surface). One datagram; a
 *  daemon that predates it, or an absolute station, ignores it. */
export function sendRehomeHintImpl(c: StreamClientLike) {
    c.writeDatagram(new Uint8Array([T_HINT]));
  }
export function sendMoveRelImpl(c: StreamClientLike, dx: number, dy: number) {
    const b = new Uint8Array(5); b[0] = T_MOVE_REL;
    const dv = new DataView(b.buffer);
    dv.setInt16(1, clampI16(dx), true);
    dv.setInt16(3, clampI16(dy), true);
    c.noteMoveWire();
    c.writeDatagram(b);
  }

  /** Diagnostic bump for one move datagram: count it and sample the datagram
   *  writer's desiredSize into the running minimum (negative ⇒ backpressure). */
export function noteMoveWireImpl(c: StreamClientLike) {
    c.moveSent++;
    const ds = c.dgWriter?.desiredSize;
    if (typeof ds === 'number' && ds < c.moveDesiredMin) c.moveDesiredMin = ds;
  }

  /** Snapshot the move-datagram wire counters for the pointer telemetry stroke
   *  accumulator (input/pointerTelemetry). desiredSizeMin is null until the
   *  first move datagram is enqueued. */
export function moveWireSnapshotImpl(c: StreamClientLike): { sent: number; rejected: number; desiredSizeMin: number | null } {
    return {
      sent: c.moveSent,
      rejected: c.moveRejected,
      desiredSizeMin: Number.isFinite(c.moveDesiredMin) ? c.moveDesiredMin : null,
    };
  }
  /** Button edge, carrying the position it happens at. `x,y` default to the last
   *  absolute position this client sent, which is where a clean tap released.
   *
   *  UNLESS THERE IS NO SUCH POSITION. A RELATIVE-pointer station ships all of
   *  its motion as type-4 RelMotion and never sends an absolute point at all, so
   *  on those the cache is empty for the whole session — and substituting its
   *  zero value put a literal abs (0,0) in the record. input/trackpad's
   *  buttonEdge omits the coords for exactly this reason (the guest clicks where
   *  its OWN cursor sits), but the omission died here: the daemon read the
   *  fabricated corner as a real target, and its abs→rel bridge pinned the guest
   *  cursor to the top-left on the first tap after every reload or resume
   *  (rhapsody, 2026-08-24 — docs/lab/INPUT-DEBUGGING.md).
   *
   *  So an unknown position is written as a SHORT record: 3 bytes, no point and
   *  no cseq. streamhost/src/input.rs case 2 takes its carried point only from a
   *  record of >= 11 bytes, so a short one is a pure edge that moves nothing —
   *  the same "no coordinates" the engine asked for, now sayable on the wire. */
export function sendButtonImpl(c: StreamClientLike, button: number, down: boolean, x?: number, y?: number) {
    // The DOWN edge only: a press and its release are one click, and counting
    // both would double every number on the scoreboard (three/usageStats).
    if (down) countClick();
    // Same edge, a different question. countClick asks "how much is this
    // MACHINE used" (the exhibit-popularity scoreboard); this asks "does the
    // pointer path get used at all". Graded `act`, so an edge with no trusted
    // human input behind it — a type-in demo, the win9x boot-modal dismissal —
    // is dropped rather than counted (analytics/intent withoutHumanCredit).
    if (down) reach('station.pointer.used', 'act');
    const px = x != null ? clampU16(x) : c.lastAbsX;
    const py = y != null ? clampU16(y) : c.lastAbsY;
    // SAMPLED per-input tracing (docs/lab/TRACE-CONTEXT.md, inputTrace.ts):
    // the browser's decision, made once per qualifying edge (key or click —
    // never a pointer-move sample). `span` is null on an untraced edge and
    // costs nothing beyond the rate check inside `maybeSampleEdge`.
    //
    // DELIBERATELY NOT ENDED HERE. `input.edge` is the ROOT of this action's
    // trace and its duration is the visitor-facing edge → painted-pixel round
    // trip, so it is closed by `inputTrace::settleEdge` when the daemon names
    // the frame that answered it — or by that module's timeout when nothing
    // ever does. Ending it here is what made every input trace's root report
    // 0–1 ms of local enqueue for something a visitor waited a quarter of a
    // second for.
    const span = maybeSampleEdge('input.edge', {
      'kh.input.class': 'click',
      'kh.station': c.stationId ?? 'unknown',
    });
    if (px == null || py == null) {
      const bare = new Uint8Array(3);
      bare[0] = T_BUTTON; bare[1] = button & 0xff; bare[2] = down ? 1 : 0;
      const rec = span ? withSuffix(bare, 3, traceSuffix(span)) : bare;
      writeTraced(span, 'stream', () => { c.writeReliableClass(ICLASS_BUTTON, rec); });
      return;
    }
    const b = new Uint8Array(11);
    b[0] = T_BUTTON; b[1] = button & 0xff; b[2] = down ? 1 : 0;
    const dv = new DataView(b.buffer);
    dv.setUint16(3, px, true);
    dv.setUint16(5, py, true);
    dv.setUint32(7, c.nextCseq(), true);
    c.lastAbsX = px; c.lastAbsY = py;
    const rec = span ? withSuffix(b, 11, traceSuffix(span)) : b;
    writeTraced(span, 'stream', () => { c.writeReliableClass(ICLASS_BUTTON, rec); });
  }
export function sendKeyScancodeImpl(c: StreamClientLike, keycode: number, down: boolean) {
    if (down) countKeystroke(keycode);
    if (down) reach('station.key.used', 'act');
    const b = new Uint8Array(4); b[0] = T_KEY; b[1] = down ? 1 : 0;
    new DataView(b.buffer).setUint16(2, keycode & 0xffff, true);
    // See sendButtonImpl above for the sampling contract. `kh.key.class` is a
    // BUCKET computed from the same scancode already on the wire (never the
    // key itself, never typed text — see inputTrace.ts's header).
    const span = maybeSampleEdge('input.edge', {
      'kh.input.class': 'key',
      'kh.key.class': keyClass(keycode),
      'kh.station': c.stationId ?? 'unknown',
    });
    const rec = span ? withSuffix(b, 4, traceSuffix(span)) : b;
    writeTraced(span, 'stream', () => { c.writeReliableClass(ICLASS_KEY, rec); });
  }
export function sendWheelImpl(c: StreamClientLike, dx: number, dy: number) {
    const b = new Uint8Array(5); b[0] = T_WHEEL;
    const dv = new DataView(b.buffer);
    dv.setInt16(1, clampI16(dx), true);
    dv.setInt16(3, clampI16(dy), true);
    c.writeReliableClass(ICLASS_WHEEL, b);
  }
