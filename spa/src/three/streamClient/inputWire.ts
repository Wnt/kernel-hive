// ============================================================================
//  three/streamClient/inputWire — the browser→daemon INPUT record encoders.
//  ---------------------------------------------------------------------------
//  Compact little-endian records, matching streamhost/src/input.rs:
//    datagrams (unreliable, high-rate, < ~200 B so they fit path MTU):
//      type 1  mouse move ABSOLUTE : u16 x, u16 y, u32 cseq  (guest needs usb-tablet)
//      type 4  mouse move RELATIVE : i16 dx, i16 dy          (PS/2-only guests)
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
import {
  ICLASS_BUTTON, ICLASS_KEY, ICLASS_WHEEL, T_BUTTON, T_KEY, T_MOVE_ABS, T_MOVE_REL, T_WHEEL,
} from './constants';

/** The parts of StreamClient these encoders touch. */
export interface StreamClientLike {
  cseq: number;
  lastAbsX: number;
  lastAbsY: number;
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
    dv.setUint32(5, c.nextCseq(), true);
    // The authoritative cursor position, for any button that follows without one
    // of its own (a tap releases where it pressed, so it sends no fresh point).
    c.lastAbsX = cx; c.lastAbsY = cy;
    c.noteMoveWire();
    c.writeDatagram(b);
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
   *  absolute position this client sent, which is where a clean tap released. */
export function sendButtonImpl(c: StreamClientLike, button: number, down: boolean, x?: number, y?: number) {
    const b = new Uint8Array(11);
    b[0] = T_BUTTON; b[1] = button & 0xff; b[2] = down ? 1 : 0;
    const dv = new DataView(b.buffer);
    const px = x != null ? clampU16(x) : c.lastAbsX;
    const py = y != null ? clampU16(y) : c.lastAbsY;
    dv.setUint16(3, px, true);
    dv.setUint16(5, py, true);
    dv.setUint32(7, c.nextCseq(), true);
    c.lastAbsX = px; c.lastAbsY = py;
    c.writeReliableClass(ICLASS_BUTTON, b);
  }
export function sendKeyScancodeImpl(c: StreamClientLike, keycode: number, down: boolean) {
    const b = new Uint8Array(4); b[0] = T_KEY; b[1] = down ? 1 : 0;
    new DataView(b.buffer).setUint16(2, keycode & 0xffff, true);
    c.writeReliableClass(ICLASS_KEY, b);
  }
export function sendWheelImpl(c: StreamClientLike, dx: number, dy: number) {
    const b = new Uint8Array(5); b[0] = T_WHEEL;
    const dv = new DataView(b.buffer);
    dv.setInt16(1, clampI16(dx), true);
    dv.setInt16(3, clampI16(dy), true);
    c.writeReliableClass(ICLASS_WHEEL, b);
  }
